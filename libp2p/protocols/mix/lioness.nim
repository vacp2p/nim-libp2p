# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## LIONESS wide-block cipher (Anderson & Biham, 1996), instantiated with
## ChaCha20 (stream cipher), keyed Blake2b-256 (hash), and SHAKE128 (KDF).
##
## The block ``B = L || R`` is split into a 32-byte left half and a right half
## of size ``len(B) - 32``, then four Feistel rounds are applied:
##
##   round 1:  R := R XOR ChaCha20(key = L XOR K1)
##   round 2:  L := L XOR Blake2b_K2(R)
##   round 3:  R := R XOR ChaCha20(key = L XOR K3)
##   round 4:  L := L XOR Blake2b_K4(R)
##
## ``K1..K4`` are derived from a 32-byte master key by feeding it into SHAKE128
## and reading 128 bytes (= 4 * 32) of output. The 12-byte ChaCha20 IV is
## supplied by the caller; ``sphinx.nim`` derives it per-hop from the shared
## secret with the same labeled-SHA-256 pattern it uses for the header
## AES-CTR keys. See ``tests/libp2p/mix/test_lioness.nim`` for vectors.
##
## LIONESS itself does not provide integrity. The Sphinx construction prepends
## ``k`` zero bytes to the plaintext before encryption and verifies them at the
## destination after decryption: tampering anywhere in the ciphertext scrambles
## the entire plaintext through the wide-block PRP, so the leading zeros are
## destroyed with overwhelming probability. See the migration design note for
## details.

{.push raises: [].}

import chronicles
import results
import nimcrypto/[blake2, keccak, utils]
import bearssl/abi/bearssl_block

logScope:
  topics = "libp2p mix lioness"

const
  LionessLeftLen* = 32
    ## Size of the left half ``L``. Must equal both the stream cipher key size
    ## and the hash output size, since L is XORed with each.
  LionessHashKeyLen* = 32
    ## Blake2b MAC key size used in the hash rounds. Sized to the master key
    ## (``LionessMasterKeyLen``); a larger MAC key cannot create entropy that
    ## the master key does not already provide.
  LionessMasterKeyLen* = 32
    ## Size of the per-hop shared-secret master key from which round keys are
    ## derived.
  LionessMinBlockLen* = LionessLeftLen * 2
    ## Minimum supported block size. The construction works for any
    ## ``|m| > LionessLeftLen``, but real Sphinx payloads are several KB; the
    ## stricter bound rejects degenerate inputs that callers never need.

  LionessIvLen* = 12
    ## ChaCha20 nonce size. The IV is supplied by the caller; in this
    ## codebase ``sphinx.nim`` derives it per-hop from the shared secret
    ## using the same labeled-SHA-256 pattern it uses for the header
    ## AES-CTR ``aes_key``/``iv`` (see ``deriveLionessIv``).

type
  LionessError* {.pure.} = enum
    BlockTooSmall
    InvalidMasterKey
    InvalidIv

  RoundKeys = object
    k1: array[LionessLeftLen, byte]
    k2: array[LionessHashKeyLen, byte]
    k3: array[LionessLeftLen, byte]
    k4: array[LionessHashKeyLen, byte]

  Lioness* = object
    ## Stateless LIONESS instance. Construct via
    ## ``Lioness.init(masterKey, iv)`` and call ``clear`` when no longer
    ## needed to wipe round keys from memory.
    keys: RoundKeys
    iv: array[LionessIvLen, byte]

func clear(self: var RoundKeys) =
  burnMem(self.k1)
  burnMem(self.k2)
  burnMem(self.k3)
  burnMem(self.k4)

func clear*(self: var Lioness) =
  ## Zeroize the derived round keys and the IV.
  self.keys.clear()
  burnMem(self.iv)

proc deriveRoundKeys(masterKey: openArray[byte]): RoundKeys =
  # Caller (``Lioness.init``) is responsible for validating ``masterKey.len``.
  # SHAKE128 supports incremental squeezing — the four sequential ``output``
  # calls below collectively produce the same byte stream as one combined
  # ``output`` call of length 2*LionessLeftLen + 2*LionessHashKeyLen.
  var ctx: shake128
  ctx.init()
  ctx.update(masterKey)
  ctx.xof()
  discard ctx.output(result.k1)
  discard ctx.output(result.k2)
  discard ctx.output(result.k3)
  discard ctx.output(result.k4)
  ctx.clear()

proc validateInitInputs(masterKeyLen, ivLen: int): Result[void, LionessError] =
  # Non-generic helper so the chronicles ``error`` template can resolve its
  # implicit ``activeChroniclesStream`` against this module's scope rather
  # than each generic instantiation site of ``Lioness.init``.
  if masterKeyLen != LionessMasterKeyLen:
    error "LIONESS init: invalid master key size",
      keyLen = masterKeyLen, expected = LionessMasterKeyLen
    return err(LionessError.InvalidMasterKey)
  if ivLen != LionessIvLen:
    error "LIONESS init: invalid iv size", ivLen = ivLen, expected = LionessIvLen
    return err(LionessError.InvalidIv)
  ok()

proc init*(
    T: type Lioness, masterKey, iv: openArray[byte]
): Result[Lioness, LionessError] =
  ## Build a LIONESS instance from a 32-byte master key and a 12-byte ChaCha20
  ## IV. Both are caller-supplied; ``sphinx.nim`` derives them per-hop with
  ## the ``"delta_key"`` and ``"delta_iv"`` labels.
  ?validateInitInputs(masterKey.len, iv.len)

  var lioness: Lioness
  lioness.keys = deriveRoundKeys(masterKey)
  for i in 0 ..< LionessIvLen:
    lioness.iv[i] = iv[i]
  ok(lioness)

# ---------------------------------------------------------------------------
# Round helpers — operate on the whole block in place; the split point is
# always ``LionessLeftLen``.
# ---------------------------------------------------------------------------

proc streamRound(
    blk: var openArray[byte], subkey: openArray[byte], iv: openArray[byte]
) =
  ## ``R ^= ChaCha20(key = L XOR subkey, iv, counter = 0)``. Length of
  ## ``subkey``, ``iv`` and ``blk`` are guaranteed by the public ``encrypt`` /
  ## ``decrypt`` callers and the fixed-size fields on ``Lioness``.
  var roundKey: array[LionessLeftLen, byte]
  for i in 0 ..< LionessLeftLen:
    roundKey[i] = blk[i] xor subkey[i]

  let rightLen = blk.len - LionessLeftLen
  discard chacha20CtRun(
    addr roundKey[0],
    unsafeAddr iv[0],
    0'u32,
    addr blk[LionessLeftLen],
    csize_t(rightLen),
  )

  burnMem(roundKey)

proc hashRound(blk: var openArray[byte], subkey: openArray[byte]) =
  ## ``L ^= Blake2b_{subkey}(R)``  (32-byte digest). Length of ``subkey`` and
  ## ``blk`` are guaranteed by the public ``encrypt`` / ``decrypt`` callers
  ## and the fixed-size fields on ``Lioness``.
  var ctx: Blake2bContext[256]
  ctx.init(subkey)
  ctx.update(blk.toOpenArray(LionessLeftLen, blk.high))
  let digest = ctx.finish()
  ctx.clear()

  for i in 0 ..< LionessLeftLen:
    blk[i] = blk[i] xor digest.data[i]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc encrypt*(self: Lioness, blk: var openArray[byte]): Result[void, LionessError] =
  ## Encrypt one wide block in place.
  if blk.len < LionessMinBlockLen:
    error "LIONESS encrypt: block below minimum size",
      blkLen = blk.len, minLen = LionessMinBlockLen
    return err(LionessError.BlockTooSmall)

  streamRound(blk, self.keys.k1, self.iv)
  hashRound(blk, self.keys.k2)
  streamRound(blk, self.keys.k3, self.iv)
  hashRound(blk, self.keys.k4)
  ok()

proc decrypt*(self: Lioness, blk: var openArray[byte]): Result[void, LionessError] =
  ## Decrypt one wide block in place. The destination hop should additionally
  ## verify the leading-zeros tag with ``hasLeadingZeros`` to detect tampering.
  if blk.len < LionessMinBlockLen:
    error "LIONESS decrypt: block below minimum size",
      blkLen = blk.len, minLen = LionessMinBlockLen
    return err(LionessError.BlockTooSmall)

  hashRound(blk, self.keys.k4)
  streamRound(blk, self.keys.k3, self.iv)
  hashRound(blk, self.keys.k2)
  streamRound(blk, self.keys.k1, self.iv)
  ok()

func hasLeadingZeros*(blk: openArray[byte], k: int): bool =
  ## True iff the first ``k`` bytes of ``blk`` are zero. Used by the destination
  ## hop after decryption to verify the integrity tag prepended by the sender.
  if blk.len < k or k < 0:
    return false
  var acc: byte = 0
  for i in 0 ..< k:
    acc = acc or blk[i]
  acc == 0
