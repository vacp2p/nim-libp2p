## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implementes API for libp2p peer.
import hashes
import nimcrypto/utils
import crypto/crypto, multicodec, multihash, base58, vbuffer
import protobuf/minprotobuf

const
  maxInlineKeyLength* = 42

type
  PeerID* = distinct seq[byte]

proc pretty*(peerid: PeerID): string {.inline.} =
  ## Return base58 encoded ``peerid`` representation.
  Base58.encode(cast[seq[byte]](peerid))

proc toBytes*(peerid: PeerID, data: var openarray[byte]): int =
  ## Store PeerID ``peerid`` to array of bytes ``data``.
  ##
  ## Returns number of bytes needed to store ``peerid``.
  var p = cast[seq[byte]](peerid)
  result = len(p)
  if len(data) >= result and result > 0:
    copyMem(addr data[0], addr p[0], result)

proc getBytes*(peerid: PeerID): seq[byte] {.inline.} =
  ## Return PeerID as array of bytes.
  var p = cast[seq[byte]](peerid)
  result = @p

proc fromKey*(pubkey: PublicKey): PeerID =
  ## Returns the PeerID corresponding to public key ``pubkey``.
  var pubraw = pubkey.getBytes()
  var mh: MultiHash
  var codec: MultiCodec
  if len(pubraw) <= maxInlineKeyLength:
    mh = MultiHash.digest("identity", pubraw)
  else:
    mh = MultiHash.digest("sha2-256", pubraw)
  result = cast[PeerID](mh.data.buffer)

proc fromKey*(seckey: PrivateKey): PeerID {.inline.} =
  ## Returns the PeerID corresponding to private key ``seckey``.
  result = fromKey(seckey.getKey())

proc hex*(peerid: PeerID): string =
  ## Returns hexadecimal string representation of ``peerid``.
  var p = cast[seq[byte]](peerid)
  if len(p) > 0:
    result = toHex(p)

proc len*(a: PeerID): int {.borrow.}

proc cmp*(a, b: PeerID): int =
  ## Compares two peer ids ``a`` and ``b``.
  ## Returns:
  ##
  ## | 0 iff a == b
  ## | < 0 iff a < b
  ## | > 0 iff a > b
  var ab = cast[seq[byte]](a)
  var bb = cast[seq[byte]](b)
  var i = 0
  var m = min(len(ab), len(bb))
  while i < m:
    result = ord(ab[i]) - ord(bb[i])
    if result != 0: return
    inc(i)
  result = len(ab) - len(bb)

proc `<=`*(a, b: PeerID): bool {.inline.} =
  (cmp(a, b) <= 0)

proc `<`*(a, b: PeerID): bool {.inline.} =
  (cmp(a, b) < 0)

proc `>=`*(a, b: PeerID): bool {.inline.} =
  (cmp(a, b) >= 0)

proc `>`*(a, b: PeerID): bool {.inline.} =
  (cmp(a, b) > 0)

proc `==`*(a, b: PeerID): bool {.inline.} =
  (cmp(a, b) == 0)

proc hash*(peerid: PeerID): Hash {.inline.} =
  var p = cast[seq[byte]](peerid)
  result = hash(p)

proc validate*(peerid: PeerID): bool =
  ## Validate check if ``peerid`` is empty or not.
  var p = cast[seq[byte]](peerid)
  if len(p) > 0:
    result = MultiHash.validate(p)

proc hasPublicKey*(peerid: PeerID): bool =
  ## Returns ``true`` if ``peerid`` is small enough to hold public key inside.
  var mh: MultiHash
  var p = cast[seq[byte]](peerid)
  if len(p) > 0:
    if MultiHash.decode(p, mh) > 0:
      if mh.mcodec == multiCodec("identity"):
        result = true

proc extractPublicKey*(peerid: PeerID, pubkey: var PublicKey): bool =
  ## Returns ``true`` if public key was successfully decoded and stored
  ## in ``pubkey``.
  ##
  ## Returns ``false`` otherwise
  var mh: MultiHash
  var p = cast[seq[byte]](peerid)
  if len(p) > 0:
    if MultiHash.decode(p, mh) > 0:
      if mh.mcodec == multiCodec("identity"):
        let length = len(mh.data.buffer)
        result = pubkey.init(mh.data.buffer.toOpenArray(mh.dpos, length - 1))

proc match*(peerid: PeerID, pubkey: PublicKey): bool {.inline.} =
  ## Returns ``true`` if ``peerid`` matches public key ``pubkey``.
  result = (peerid == pubkey.fromKey())

proc match*(peerid: PeerID, seckey: PrivateKey): bool {.inline.} =
  ## Returns ``true`` if ``peerid`` matches private key ``seckey``.
  result = (peerid == seckey.fromKey())

proc `$`*(peerid: PeerID): string =
  ## Returns compact string representation of ``peerid``.
  var pid = peerid.pretty()
  if len(pid) <= 10:
    result = pid
  else:
    for i in 0..<2:
      result.add(pid[i])
    result.add("*")
    for i in (len(pid) - 6)..(len(pid) - 1):
      result.add(pid[i])

proc write*(vb: var VBuffer, peerid: PeerID) {.inline.} =
  ## Write PeerID value ``peerid`` to buffer ``vb``.
  var p = cast[seq[byte]](peerid)
  vb.writeSeq(p)

proc initProtoField*(index: int, peerid: PeerID): ProtoField =
  ## Initialize ProtoField with PeerID ``value``.
  var p = cast[seq[byte]](peerid)
  result = initProtoField(index, p)

proc getValue*(data: var ProtoBuffer, field: int, value: var PeerID): int =
  ## Read ``PeerID`` from ProtoBuf's message and validate it.
  var buffer: seq[byte]
  result = getLengthValue(data, field, buffer)
  if result > 0:
    value = cast[PeerID](buffer)
    if not value.validate():
      result = -1
