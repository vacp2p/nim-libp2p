## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements ED25519.
## This code is a port of the public domain, "ref10" implementation of ed25519
## from SUPERCOP.

{.push raises: Defect.}

import constants, bearssl
import nimcrypto/[hash, sha2]
# We use `ncrutils` for constant-time hexadecimal encoding/decoding procedures.
import nimcrypto/utils as ncrutils
import stew/[results, ctops]
export results

# This workaround needed because of some bugs in Nim Static[T].
export hash, sha2

const
  EdPrivateKeySize* = 64
    ## Size in octets (bytes) of serialized ED25519 private key.
  EdPublicKeySize* = 32
    ## Size in octets (bytes) of serialized ED25519 public key.
  EdSignatureSize* = 64
    ## Size in octets (bytes) of serialized ED25519 signature.

type
  EdPrivateKey* = object
    data*: array[EdPrivateKeySize, byte]

  EdPublicKey* = object
    data*: array[EdPublicKeySize, byte]

  EdSignature* = object
    data*: array[EdSignatureSize, byte]

  EdKeyPair* = object
    seckey*: EdPrivateKey
    pubkey*: EdPublicKey

  EdError* = enum
    EdIncorrectError

proc `-`(x: uint32): uint32 {.inline.} =
  result = (0xFFFF_FFFF'u32 - x) + 1'u32

proc `-`(x: uint8): uint8 {.inline.} =
  result = (0xFF'u8 - x) + 1'u8

proc fe0(h: var Fe) =
  h[0] = 0; h[1] = 0; h[2] = 0; h[3] = 0; h[4] = 0
  h[5] = 0; h[6] = 0; h[7] = 0; h[8] = 0; h[9] = 0

proc fe1(h: var Fe) =
  h[0] = 1; h[1] = 0; h[2] = 0; h[3] = 0; h[4] = 0
  h[5] = 0; h[6] = 0; h[7] = 0; h[8] = 0; h[9] = 0

proc feAdd(h: var Fe, f, g: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var g0 = g[0]; var g1 = g[1]; var g2 = g[2]; var g3 = g[3]; var g4 = g[4]
  var g5 = g[5]; var g6 = g[6]; var g7 = g[7]; var g8 = g[8]; var g9 = g[9]
  var h0 = f0 + g0
  var h1 = f1 + g1
  var h2 = f2 + g2
  var h3 = f3 + g3
  var h4 = f4 + g4
  var h5 = f5 + g5
  var h6 = f6 + g6
  var h7 = f7 + g7
  var h8 = f8 + g8
  var h9 = f9 + g9
  h[0] = h0
  h[1] = h1
  h[2] = h2
  h[3] = h3
  h[4] = h4
  h[5] = h5
  h[6] = h6
  h[7] = h7
  h[8] = h8
  h[9] = h9

proc feSub(h: var Fe, f, g: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var g0 = g[0]; var g1 = g[1]; var g2 = g[2]; var g3 = g[3]; var g4 = g[4]
  var g5 = g[5]; var g6 = g[6]; var g7 = g[7]; var g8 = g[8]; var g9 = g[9]
  var h0 = f0 - g0
  var h1 = f1 - g1
  var h2 = f2 - g2
  var h3 = f3 - g3
  var h4 = f4 - g4
  var h5 = f5 - g5
  var h6 = f6 - g6
  var h7 = f7 - g7
  var h8 = f8 - g8
  var h9 = f9 - g9
  h[0] = h0
  h[1] = h1
  h[2] = h2
  h[3] = h3
  h[4] = h4
  h[5] = h5
  h[6] = h6
  h[7] = h7
  h[8] = h8
  h[9] = h9

proc feCmov(f: var Fe, g: Fe, b: uint32) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var g0 = g[0]; var g1 = g[1]; var g2 = g[2]; var g3 = g[3]; var g4 = g[4]
  var g5 = g[5]; var g6 = g[6]; var g7 = g[7]; var g8 = g[8]; var g9 = g[9]
  var x0 = f0 xor g0
  var x1 = f1 xor g1
  var x2 = f2 xor g2
  var x3 = f3 xor g3
  var x4 = f4 xor g4
  var x5 = f5 xor g5
  var x6 = f6 xor g6
  var x7 = f7 xor g7
  var x8 = f8 xor g8
  var x9 = f9 xor g9
  var bc = -b
  x0 = x0 and cast[int32](bc)
  x1 = x1 and cast[int32](bc)
  x2 = x2 and cast[int32](bc)
  x3 = x3 and cast[int32](bc)
  x4 = x4 and cast[int32](bc)
  x5 = x5 and cast[int32](bc)
  x6 = x6 and cast[int32](bc)
  x7 = x7 and cast[int32](bc)
  x8 = x8 and cast[int32](bc)
  x9 = x9 and cast[int32](bc)
  f[0] = f0 xor x0
  f[1] = f1 xor x1
  f[2] = f2 xor x2
  f[3] = f3 xor x3
  f[4] = f4 xor x4
  f[5] = f5 xor x5
  f[6] = f6 xor x6
  f[7] = f7 xor x7
  f[8] = f8 xor x8
  f[9] = f9 xor x9

proc feCopy(h: var Fe, f: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  h[0] = f0
  h[1] = f1
  h[2] = f2
  h[3] = f3
  h[4] = f4
  h[5] = f5
  h[6] = f6
  h[7] = f7
  h[8] = f8
  h[9] = f9

proc load_3(inp: openArray[byte]): uint64 =
  result = cast[uint64](inp[0])
  result = result or (cast[uint64](inp[1]) shl 8)
  result = result or (cast[uint64](inp[2]) shl 16)

proc load_4(inp: openArray[byte]): uint64 =
  result = cast[uint64](inp[0])
  result = result or (cast[uint64](inp[1]) shl 8)
  result = result or (cast[uint64](inp[2]) shl 16)
  result = result or (cast[uint64](inp[3]) shl 24)

proc feFromBytes(h: var Fe, s: openArray[byte]) =
  var c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: int64

  var h0 = cast[int64](load_4(s.toOpenArray(0, 3)))
  var h1 = cast[int64](load_3(s.toOpenArray(4, 6))) shl 6
  var h2 = cast[int64](load_3(s.toOpenArray(7, 9))) shl 5
  var h3 = cast[int64](load_3(s.toOpenArray(10, 12))) shl 3
  var h4 = cast[int64](load_3(s.toOpenArray(13, 15))) shl 2
  var h5 = cast[int64](load_4(s.toOpenArray(16, 19)))
  var h6 = cast[int64](load_3(s.toOpenArray(20, 22))) shl 7
  var h7 = cast[int64](load_3(s.toOpenArray(23, 25))) shl 5
  var h8 = cast[int64](load_3(s.toOpenArray(26, 28))) shl 4
  var h9 = (cast[int64](load_3(s.toOpenArray(29, 31))) and 8388607'i32) shl 2

  c9 = ashr((h9 + (1'i64 shl 24)), 25); h0 = h0 + (c9 * 19); h9 -= (c9 shl 25)
  c1 = ashr((h1 + (1'i64 shl 24)), 25); h2 = h2 + c1; h1 -= (c1 shl 25)
  c3 = ashr((h3 + (1'i64 shl 24)), 25); h4 = h4 + c3; h3 -= (c3 shl 25)
  c5 = ashr((h5 + (1'i64 shl 24)), 25); h6 = h6 + c5; h5 -= (c5 shl 25)
  c7 = ashr((h7 + (1'i64 shl 24)), 25); h8 = h8 + c7; h7 -= (c7 shl 25)

  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 = h1 + c0; h0 -= (c0 shl 26)
  c2 = ashr((h2 + (1'i64 shl 25)), 26); h3 = h3 + c2; h2 -= (c2 shl 26)
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 = h5 + c4; h4 -= (c4 shl 26)
  c6 = ashr((h6 + (1'i64 shl 25)), 26); h7 = h7 + c6; h6 -= (c6 shl 26)
  c8 = ashr((h8 + (1'i64 shl 25)), 26); h9 = h9 + c8; h8 -= (c8 shl 26)

  h[0] = cast[int32](h0)
  h[1] = cast[int32](h1)
  h[2] = cast[int32](h2)
  h[3] = cast[int32](h3)
  h[4] = cast[int32](h4)
  h[5] = cast[int32](h5)
  h[6] = cast[int32](h6)
  h[7] = cast[int32](h7)
  h[8] = cast[int32](h8)
  h[9] = cast[int32](h9)

proc feToBytes(s: var openArray[byte], h: Fe) =
  var h0 = h[0]; var h1 = h[1]; var h2 = h[2]; var h3 = h[3]; var h4 = h[4]
  var h5 = h[5]; var h6 = h[6]; var h7 = h[7]; var h8 = h[8]; var h9 = h[9]
  var q, c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: int32

  q = ashr((19 * h9 + (1'i32 shl 24)), 25)
  q = ashr(h0 + q, 26)
  q = ashr(h1 + q, 25)
  q = ashr(h2 + q, 26)
  q = ashr(h3 + q, 25)
  q = ashr(h4 + q, 26)
  q = ashr(h5 + q, 25)
  q = ashr(h6 + q, 26)
  q = ashr(h7 + q, 25)
  q = ashr(h8 + q, 26)
  q = ashr(h9 + q, 25)

  h0 = h0 + 19 * q

  c0 = ashr(h0, 26); h1 += c0; h0 -= c0 shl 26;
  c1 = ashr(h1, 25); h2 += c1; h1 -= c1 shl 25;
  c2 = ashr(h2, 26); h3 += c2; h2 -= c2 shl 26;
  c3 = ashr(h3, 25); h4 += c3; h3 -= c3 shl 25;
  c4 = ashr(h4, 26); h5 += c4; h4 -= c4 shl 26;
  c5 = ashr(h5, 25); h6 += c5; h5 -= c5 shl 25;
  c6 = ashr(h6, 26); h7 += c6; h6 -= c6 shl 26;
  c7 = ashr(h7, 25); h8 += c7; h7 -= c7 shl 25;
  c8 = ashr(h8, 26); h9 += c8; h8 -= c8 shl 26;
  c9 = ashr(h9, 25);           h9 -= c9 shl 25;

  s[0] = cast[byte](ashr(h0, 0))
  s[1] = cast[byte](ashr(h0, 8))
  s[2] = cast[byte](ashr(h0, 16))
  s[3] = cast[byte]((ashr(h0, 24) or (h1 shl 2)))
  s[4] = cast[byte](ashr(h1, 6))
  s[5] = cast[byte](ashr(h1, 14))
  s[6] = cast[byte]((ashr(h1, 22) or (h2 shl 3)))
  s[7] = cast[byte](ashr(h2, 5))
  s[8] = cast[byte](ashr(h2, 13))
  s[9] = cast[byte]((ashr(h2, 21) or (h3 shl 5)))
  s[10] = cast[byte](ashr(h3, 3))
  s[11] = cast[byte](ashr(h3, 11))
  s[12] = cast[byte]((ashr(h3, 19) or (h4 shl 6)))
  s[13] = cast[byte](ashr(h4, 2))
  s[14] = cast[byte](ashr(h4, 10))
  s[15] = cast[byte](ashr(h4, 18))
  s[16] = cast[byte](ashr(h5, 0))
  s[17] = cast[byte](ashr(h5, 8))
  s[18] = cast[byte](ashr(h5, 16))
  s[19] = cast[byte]((ashr(h5, 24) or (h6 shl 1)))
  s[20] = cast[byte](ashr(h6, 7))
  s[21] = cast[byte](ashr(h6, 15))
  s[22] = cast[byte]((ashr(h6, 23) or (h7 shl 3)))
  s[23] = cast[byte](ashr(h7, 5))
  s[24] = cast[byte](ashr(h7, 13))
  s[25] = cast[byte]((ashr(h7, 21) or (h8 shl 4)))
  s[26] = cast[byte](ashr(h8, 4))
  s[27] = cast[byte](ashr(h8, 12))
  s[28] = cast[byte]((ashr(h8, 20) or (h9 shl 6)))
  s[29] = cast[byte](ashr(h9, 2))
  s[30] = cast[byte](ashr(h9, 10))
  s[31] = cast[byte](ashr(h9, 18))

proc feMul(h: var Fe, f, g: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var g0 = g[0]; var g1 = g[1]; var g2 = g[2]; var g3 = g[3]; var g4 = g[4]
  var g5 = g[5]; var g6 = g[6]; var g7 = g[7]; var g8 = g[8]; var g9 = g[9]
  var g1_19 = 19 * g1
  var g2_19 = 19 * g2
  var g3_19 = 19 * g3
  var g4_19 = 19 * g4
  var g5_19 = 19 * g5
  var g6_19 = 19 * g6
  var g7_19 = 19 * g7
  var g8_19 = 19 * g8
  var g9_19 = 19 * g9
  var f1_2 = 2 * f1
  var f3_2 = 2 * f3
  var f5_2 = 2 * f5
  var f7_2 = 2 * f7
  var f9_2 = 2 * f9
  var f0g0 = cast[int64](f0) * cast[int64](g0)
  var f0g1 = cast[int64](f0) * cast[int64](g1)
  var f0g2 = cast[int64](f0) * cast[int64](g2)
  var f0g3 = cast[int64](f0) * cast[int64](g3)
  var f0g4 = cast[int64](f0) * cast[int64](g4)
  var f0g5 = cast[int64](f0) * cast[int64](g5)
  var f0g6 = cast[int64](f0) * cast[int64](g6)
  var f0g7 = cast[int64](f0) * cast[int64](g7)
  var f0g8 = cast[int64](f0) * cast[int64](g8)
  var f0g9 = cast[int64](f0) * cast[int64](g9)
  var f1g0 = cast[int64](f1) * cast[int64](g0)
  var f1g1_2 = cast[int64](f1_2) * cast[int64](g1)
  var f1g2 = cast[int64](f1) * cast[int64](g2)
  var f1g3_2 = cast[int64](f1_2) * cast[int64](g3)
  var f1g4 = cast[int64](f1) * cast[int64](g4)
  var f1g5_2 = cast[int64](f1_2) * cast[int64](g5)
  var f1g6 = cast[int64](f1) * cast[int64](g6)
  var f1g7_2 = cast[int64](f1_2) * cast[int64](g7)
  var f1g8 = cast[int64](f1) * cast[int64](g8)
  var f1g9_38 = cast[int64](f1_2) * cast[int64](g9_19)
  var f2g0 = cast[int64](f2) * cast[int64](g0)
  var f2g1 = cast[int64](f2) * cast[int64](g1)
  var f2g2 = cast[int64](f2) * cast[int64](g2)
  var f2g3 = cast[int64](f2) * cast[int64](g3)
  var f2g4 = cast[int64](f2) * cast[int64](g4)
  var f2g5 = cast[int64](f2) * cast[int64](g5)
  var f2g6 = cast[int64](f2) * cast[int64](g6)
  var f2g7 = cast[int64](f2) * cast[int64](g7)
  var f2g8_19 = cast[int64](f2) * cast[int64](g8_19)
  var f2g9_19 = cast[int64](f2) * cast[int64](g9_19)
  var f3g0 = cast[int64](f3) * cast[int64](g0)
  var f3g1_2  = cast[int64](f3_2) * cast[int64](g1)
  var f3g2 = cast[int64](f3) * cast[int64](g2)
  var f3g3_2  = cast[int64](f3_2) * cast[int64](g3)
  var f3g4 = cast[int64](f3) * cast[int64](g4)
  var f3g5_2  = cast[int64](f3_2) * cast[int64](g5)
  var f3g6 = cast[int64](f3) * cast[int64](g6)
  var f3g7_38 = cast[int64](f3_2) * cast[int64](g7_19)
  var f3g8_19 = cast[int64](f3) * cast[int64](g8_19)
  var f3g9_38 = cast[int64](f3_2) * cast[int64](g9_19)
  var f4g0 = cast[int64](f4) * cast[int64](g0)
  var f4g1 = cast[int64](f4) * cast[int64](g1)
  var f4g2 = cast[int64](f4) * cast[int64](g2)
  var f4g3 = cast[int64](f4) * cast[int64](g3)
  var f4g4 = cast[int64](f4) * cast[int64](g4)
  var f4g5 = cast[int64](f4) * cast[int64](g5)
  var f4g6_19 = cast[int64](f4) * cast[int64](g6_19)
  var f4g7_19 = cast[int64](f4) * cast[int64](g7_19)
  var f4g8_19 = cast[int64](f4) * cast[int64](g8_19)
  var f4g9_19 = cast[int64](f4) * cast[int64](g9_19)
  var f5g0 = cast[int64](f5) * cast[int64](g0)
  var f5g1_2 = cast[int64](f5_2) * cast[int64](g1)
  var f5g2 = cast[int64](f5) * cast[int64](g2)
  var f5g3_2 = cast[int64](f5_2) * cast[int64](g3)
  var f5g4 = cast[int64](f5) * cast[int64](g4)
  var f5g5_38 = cast[int64](f5_2) * cast[int64](g5_19)
  var f5g6_19 = cast[int64](f5) * cast[int64](g6_19)
  var f5g7_38 = cast[int64](f5_2) * cast[int64](g7_19)
  var f5g8_19 = cast[int64](f5) * cast[int64](g8_19)
  var f5g9_38 = cast[int64](f5_2) * cast[int64](g9_19)
  var f6g0 = cast[int64](f6) * cast[int64](g0)
  var f6g1 = cast[int64](f6) * cast[int64](g1)
  var f6g2 = cast[int64](f6) * cast[int64](g2)
  var f6g3 = cast[int64](f6) * cast[int64](g3)
  var f6g4_19 = cast[int64](f6) * cast[int64](g4_19)
  var f6g5_19 = cast[int64](f6) * cast[int64](g5_19)
  var f6g6_19 = cast[int64](f6) * cast[int64](g6_19)
  var f6g7_19 = cast[int64](f6) * cast[int64](g7_19)
  var f6g8_19 = cast[int64](f6) * cast[int64](g8_19)
  var f6g9_19 = cast[int64](f6) * cast[int64](g9_19)
  var f7g0 = cast[int64](f7) * cast[int64](g0)
  var f7g1_2 = cast[int64](f7_2) * cast[int64](g1)
  var f7g2 = cast[int64](f7) * cast[int64](g2)
  var f7g3_38 = cast[int64](f7_2) * cast[int64](g3_19)
  var f7g4_19 = cast[int64](f7) * cast[int64](g4_19)
  var f7g5_38 = cast[int64](f7_2) * cast[int64](g5_19)
  var f7g6_19 = cast[int64](f7) * cast[int64](g6_19)
  var f7g7_38 = cast[int64](f7_2) * cast[int64](g7_19)
  var f7g8_19 = cast[int64](f7) * cast[int64](g8_19)
  var f7g9_38 = cast[int64](f7_2) * cast[int64](g9_19)
  var f8g0 = cast[int64](f8) * cast[int64](g0)
  var f8g1 = cast[int64](f8) * cast[int64](g1)
  var f8g2_19 = cast[int64](f8) * cast[int64](g2_19)
  var f8g3_19 = cast[int64](f8) * cast[int64](g3_19)
  var f8g4_19 = cast[int64](f8) * cast[int64](g4_19)
  var f8g5_19 = cast[int64](f8) * cast[int64](g5_19)
  var f8g6_19 = cast[int64](f8) * cast[int64](g6_19)
  var f8g7_19 = cast[int64](f8) * cast[int64](g7_19)
  var f8g8_19 = cast[int64](f8) * cast[int64](g8_19)
  var f8g9_19 = cast[int64](f8) * cast[int64](g9_19)
  var f9g0 = cast[int64](f9) * cast[int64](g0)
  var f9g1_38 = cast[int64](f9_2) * cast[int64](g1_19)
  var f9g2_19 = cast[int64](f9) * cast[int64](g2_19)
  var f9g3_38 = cast[int64](f9_2) * cast[int64](g3_19)
  var f9g4_19 = cast[int64](f9) * cast[int64](g4_19)
  var f9g5_38 = cast[int64](f9_2) * cast[int64](g5_19)
  var f9g6_19 = cast[int64](f9) * cast[int64](g6_19)
  var f9g7_38 = cast[int64](f9_2) * cast[int64](g7_19)
  var f9g8_19 = cast[int64](f9) * cast[int64](g8_19)
  var f9g9_38 = cast[int64](f9_2) * cast[int64](g9_19)
  var
    c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: int64
    h0: int64 = f0g0 + f1g9_38 + f2g8_19 + f3g7_38 + f4g6_19 + f5g5_38 +
                f6g4_19 + f7g3_38 + f8g2_19 + f9g1_38
    h1: int64 = f0g1 + f1g0 + f2g9_19 + f3g8_19 + f4g7_19 + f5g6_19 +
                f6g5_19 + f7g4_19 + f8g3_19 + f9g2_19
    h2: int64 = f0g2 + f1g1_2 + f2g0 + f3g9_38 + f4g8_19 + f5g7_38 + f6g6_19 +
                f7g5_38 + f8g4_19 + f9g3_38
    h3: int64 = f0g3 + f1g2 + f2g1 + f3g0 + f4g9_19 + f5g8_19 + f6g7_19 +
                f7g6_19 + f8g5_19 + f9g4_19
    h4: int64 = f0g4 + f1g3_2 + f2g2 + f3g1_2 + f4g0 + f5g9_38 + f6g8_19 +
                f7g7_38 + f8g6_19 + f9g5_38
    h5: int64 = f0g5 + f1g4 + f2g3 + f3g2 + f4g1 + f5g0 + f6g9_19 + f7g8_19 +
                f8g7_19 + f9g6_19
    h6: int64 = f0g6 + f1g5_2 + f2g4 + f3g3_2 + f4g2 + f5g1_2 + f6g0 +
                f7g9_38 + f8g8_19 + f9g7_38
    h7: int64 = f0g7 + f1g6 + f2g5 + f3g4 + f4g3 + f5g2 + f6g1 + f7g0 +
                f8g9_19 + f9g8_19
    h8: int64 = f0g8 + f1g7_2 + f2g6 + f3g5_2 + f4g4 + f5g3_2 + f6g2 +
                f7g1_2 + f8g0 + f9g9_38
    h9: int64 = f0g9 + f1g8 + f2g7 + f3g6 + f4g5 + f5g4 + f6g3 + f7g2 +
                f8g1 + f9g0

  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 = h1 + c0; h0 -= (c0 shl 26)
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 = h5 + c4; h4 -= (c4 shl 26)
  c1 = ashr((h1 + (1'i64 shl 24)), 25); h2 = h2 + c1; h1 -= (c1 shl 25)
  c5 = ashr((h5 + (1'i64 shl 24)), 25); h6 = h6 + c5; h5 -= (c5 shl 25)
  c2 = ashr((h2 + (1'i64 shl 25)), 26); h3 = h3 + c2; h2 -= (c2 shl 26)
  c6 = ashr((h6 + (1'i64 shl 25)), 26); h7 = h7 + c6; h6 -= (c6 shl 26)
  c3 = ashr((h3 + (1'i64 shl 24)), 25); h4 = h4 + c3; h3 -= (c3 shl 25)
  c7 = ashr((h7 + (1'i64 shl 24)), 25); h8 = h8 + c7; h7 -= (c7 shl 25)
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 = h5 + c4; h4 -= (c4 shl 26)
  c8 = ashr((h8 + (1'i64 shl 25)), 26); h9 = h9 + c8; h8 -= (c8 shl 26)
  c9 = ashr((h9 + (1'i64 shl 24)), 25); h0 = h0 + (c9 * 19); h9 -= (c9 shl 25)
  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 = h1 + c0; h0 -= (c0 shl 26)

  h[0] = cast[int32](h0)
  h[1] = cast[int32](h1)
  h[2] = cast[int32](h2)
  h[3] = cast[int32](h3)
  h[4] = cast[int32](h4)
  h[5] = cast[int32](h5)
  h[6] = cast[int32](h6)
  h[7] = cast[int32](h7)
  h[8] = cast[int32](h8)
  h[9] = cast[int32](h9)

proc feNeg(h: var Fe, f: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var h0 = -f0; var h1 = -f1; var h2 = -f2; var h3 = -f3; var h4 = -f4
  var h5 = -f5; var h6 = -f6; var h7 = -f7; var h8 = -f8; var h9 = -f9
  h[0] = h0; h[1] = h1; h[2] = h2; h[3] = h3; h[4] = h4
  h[5] = h5; h[6] = h6; h[7] = h7; h[8] = h8; h[9] = h9

proc verify32(x: openArray[byte], y: openArray[byte]): int32 =
  var d = 0'u32
  d = d or (x[0] xor y[0])
  d = d or (x[1] xor y[1])
  d = d or (x[2] xor y[2])
  d = d or (x[3] xor y[3])
  d = d or (x[4] xor y[4])
  d = d or (x[5] xor y[5])
  d = d or (x[6] xor y[6])
  d = d or (x[7] xor y[7])
  d = d or (x[8] xor y[8])
  d = d or (x[9] xor y[9])
  d = d or (x[10] xor y[10])
  d = d or (x[11] xor y[11])
  d = d or (x[12] xor y[12])
  d = d or (x[13] xor y[13])
  d = d or (x[14] xor y[14])
  d = d or (x[15] xor y[15])
  d = d or (x[16] xor y[16])
  d = d or (x[17] xor y[17])
  d = d or (x[18] xor y[18])
  d = d or (x[19] xor y[19])
  d = d or (x[20] xor y[20])
  d = d or (x[21] xor y[21])
  d = d or (x[22] xor y[22])
  d = d or (x[23] xor y[23])
  d = d or (x[24] xor y[24])
  d = d or (x[25] xor y[25])
  d = d or (x[26] xor y[26])
  d = d or (x[27] xor y[27])
  d = d or (x[28] xor y[28])
  d = d or (x[29] xor y[29])
  d = d or (x[30] xor y[30])
  d = d or (x[31] xor y[31])
  result = cast[int32]((1'u32 and ((d - 1) shr 8)) - 1)

proc feIsNegative(f: Fe): int32 =
  var s: array[32, byte]
  feToBytes(s, f)
  result = cast[int32](s[0] and 1'u8)

proc feIsNonZero(f: Fe): int32 =
  var s: array[32, byte]
  feToBytes(s, f)
  result = verify32(s, ZeroFe)

proc feSq(h: var Fe, f: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4];
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9];
  var f0_2: int32 = 2 * f0
  var f1_2: int32 = 2 * f1
  var f2_2: int32 = 2 * f2
  var f3_2: int32 = 2 * f3
  var f4_2: int32 = 2 * f4
  var f5_2: int32 = 2 * f5
  var f6_2: int32 = 2 * f6
  var f7_2: int32 = 2 * f7
  var f5_38: int32 = 38 * f5
  var f6_19: int32 = 19 * f6
  var f7_38: int32 = 38 * f7
  var f8_19: int32 = 19 * f8
  var f9_38: int32 = 38 * f9
  var f0f0: int64 = f0 * cast[int64](f0)
  var f0f1_2: int64 = f0_2 * cast[int64](f1)
  var f0f2_2: int64 = f0_2 * cast[int64](f2)
  var f0f3_2: int64 = f0_2 * cast[int64](f3)
  var f0f4_2: int64 = f0_2 * cast[int64](f4)
  var f0f5_2: int64 = f0_2 * cast[int64](f5)
  var f0f6_2: int64 = f0_2 * cast[int64](f6)
  var f0f7_2: int64 = f0_2 * cast[int64](f7)
  var f0f8_2: int64 = f0_2 * cast[int64](f8)
  var f0f9_2: int64 = f0_2 * cast[int64](f9)
  var f1f1_2: int64 = f1_2 * cast[int64](f1)
  var f1f2_2: int64 = f1_2 * cast[int64](f2)
  var f1f3_4: int64 = f1_2 * cast[int64](f3_2)
  var f1f4_2: int64 = f1_2 * cast[int64](f4)
  var f1f5_4: int64 = f1_2 * cast[int64](f5_2)
  var f1f6_2: int64 = f1_2 * cast[int64](f6)
  var f1f7_4: int64 = f1_2 * cast[int64](f7_2)
  var f1f8_2: int64 = f1_2 * cast[int64](f8)
  var f1f9_76: int64 = f1_2 * cast[int64](f9_38)
  var f2f2: int64 = f2 * cast[int64](f2)
  var f2f3_2: int64 = f2_2 * cast[int64](f3)
  var f2f4_2: int64 = f2_2 * cast[int64](f4)
  var f2f5_2: int64 = f2_2 * cast[int64](f5)
  var f2f6_2: int64 = f2_2 * cast[int64](f6)
  var f2f7_2: int64 = f2_2 * cast[int64](f7)
  var f2f8_38: int64 = f2_2 * cast[int64](f8_19)
  var f2f9_38: int64 = f2 * cast[int64](f9_38)
  var f3f3_2: int64 = f3_2 * cast[int64](f3)
  var f3f4_2: int64 = f3_2 * cast[int64](f4)
  var f3f5_4: int64 = f3_2 * cast[int64](f5_2)
  var f3f6_2: int64 = f3_2 * cast[int64](f6)
  var f3f7_76: int64 = f3_2 * cast[int64](f7_38)
  var f3f8_38: int64 = f3_2 * cast[int64](f8_19)
  var f3f9_76: int64 = f3_2 * cast[int64](f9_38)
  var f4f4: int64 = f4 * cast[int64](f4)
  var f4f5_2: int64 = f4_2 * cast[int64](f5)
  var f4f6_38: int64 = f4_2 * cast[int64](f6_19)
  var f4f7_38: int64 = f4 * cast[int64](f7_38)
  var f4f8_38: int64 = f4_2 * cast[int64](f8_19)
  var f4f9_38: int64 = f4 * cast[int64](f9_38)
  var f5f5_38: int64 = f5 * cast[int64](f5_38)
  var f5f6_38: int64 = f5_2 * cast[int64](f6_19)
  var f5f7_76: int64 = f5_2 * cast[int64](f7_38)
  var f5f8_38: int64 = f5_2 * cast[int64](f8_19)
  var f5f9_76: int64 = f5_2 * cast[int64](f9_38)
  var f6f6_19: int64 = f6 * cast[int64](f6_19)
  var f6f7_38: int64 = f6 * cast[int64](f7_38)
  var f6f8_38: int64 = f6_2 * cast[int64](f8_19)
  var f6f9_38: int64 = f6 * cast[int64](f9_38)
  var f7f7_38: int64 = f7 * cast[int64](f7_38)
  var f7f8_38: int64 = f7_2 * cast[int64](f8_19)
  var f7f9_76: int64 = f7_2 * cast[int64](f9_38)
  var f8f8_19: int64 = f8 * cast[int64](f8_19)
  var f8f9_38: int64 = f8 * cast[int64](f9_38)
  var f9f9_38: int64 = f9 * cast[int64](f9_38)
  var h0: int64 = f0f0 + f1f9_76 + f2f8_38 + f3f7_76 + f4f6_38 + f5f5_38
  var h1: int64 = f0f1_2 + f2f9_38 + f3f8_38 + f4f7_38 + f5f6_38
  var h2: int64 = f0f2_2 + f1f1_2 + f3f9_76 + f4f8_38 + f5f7_76 + f6f6_19
  var h3: int64 = f0f3_2 + f1f2_2 + f4f9_38 + f5f8_38 + f6f7_38
  var h4: int64 = f0f4_2 + f1f3_4 + f2f2 + f5f9_76 + f6f8_38 + f7f7_38
  var h5: int64 = f0f5_2 + f1f4_2 + f2f3_2 + f6f9_38 + f7f8_38
  var h6: int64 = f0f6_2 + f1f5_4 + f2f4_2 + f3f3_2 + f7f9_76 + f8f8_19
  var h7: int64 = f0f7_2 + f1f6_2 + f2f5_2 + f3f4_2 + f8f9_38
  var h8: int64 = f0f8_2 + f1f7_4 + f2f6_2 + f3f5_4 + f4f4 + f9f9_38
  var h9: int64 = f0f9_2 + f1f8_2 + f2f7_2 + f3f6_2 + f4f5_2
  var c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: int64

  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 += c0; h0 -= c0 shl 26
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 += c4; h4 -= c4 shl 26
  c1 = ashr((h1 + (1'i64 shl 24)), 25); h2 += c1; h1 -= c1 shl 25
  c5 = ashr((h5 + (1'i64 shl 24)), 25); h6 += c5; h5 -= c5 shl 25
  c2 = ashr((h2 + (1'i64 shl 25)), 26); h3 += c2; h2 -= c2 shl 26
  c6 = ashr((h6 + (1'i64 shl 25)), 26); h7 += c6; h6 -= c6 shl 26
  c3 = ashr((h3 + (1'i64 shl 24)), 25); h4 += c3; h3 -= c3 shl 25
  c7 = ashr((h7 + (1'i64 shl 24)), 25); h8 += c7; h7 -= c7 shl 25
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 += c4; h4 -= c4 shl 26
  c8 = ashr((h8 + (1'i64 shl 25)), 26); h9 += c8; h8 -= c8 shl 26
  c9 = ashr((h9 + (1'i64 shl 24)), 25); h0 += c9 * 19; h9 -= c9 shl 25
  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 += c0; h0 -= c0 shl 26

  h[0] = cast[int32](h0)
  h[1] = cast[int32](h1)
  h[2] = cast[int32](h2)
  h[3] = cast[int32](h3)
  h[4] = cast[int32](h4)
  h[5] = cast[int32](h5)
  h[6] = cast[int32](h6)
  h[7] = cast[int32](h7)
  h[8] = cast[int32](h8)
  h[9] = cast[int32](h9)

proc feSq2(h: var Fe, f: Fe) =
  var f0 = f[0]; var f1 = f[1]; var f2 = f[2]; var f3 = f[3]; var f4 = f[4]
  var f5 = f[5]; var f6 = f[6]; var f7 = f[7]; var f8 = f[8]; var f9 = f[9]
  var f0_2 = 2 * f0
  var f1_2 = 2 * f1
  var f2_2 = 2 * f2
  var f3_2 = 2 * f3
  var f4_2 = 2 * f4
  var f5_2 = 2 * f5
  var f6_2 = 2 * f6
  var f7_2 = 2 * f7
  var f5_38 = 38 * f5
  var f6_19 = 19 * f6
  var f7_38 = 38 * f7
  var f8_19 = 19 * f8
  var f9_38 = 38 * f9
  var f0f0 = cast[int64](f0) * cast[int64](f0)
  var f0f1_2 = cast[int64](f0_2) * cast[int64](f1)
  var f0f2_2 = cast[int64](f0_2) * cast[int64](f2)
  var f0f3_2 = cast[int64](f0_2) * cast[int64](f3)
  var f0f4_2 = cast[int64](f0_2) * cast[int64](f4)
  var f0f5_2 = cast[int64](f0_2) * cast[int64](f5)
  var f0f6_2 = cast[int64](f0_2) * cast[int64](f6)
  var f0f7_2 = cast[int64](f0_2) * cast[int64](f7)
  var f0f8_2 = cast[int64](f0_2) * cast[int64](f8)
  var f0f9_2 = cast[int64](f0_2) * cast[int64](f9)
  var f1f1_2 = cast[int64](f1_2) * cast[int64](f1)
  var f1f2_2 = cast[int64](f1_2) * cast[int64](f2)
  var f1f3_4 = cast[int64](f1_2) * cast[int64](f3_2)
  var f1f4_2 = cast[int64](f1_2) * cast[int64](f4)
  var f1f5_4 = cast[int64](f1_2) * cast[int64](f5_2)
  var f1f6_2 = cast[int64](f1_2) * cast[int64](f6)
  var f1f7_4 = cast[int64](f1_2) * cast[int64](f7_2)
  var f1f8_2 = cast[int64](f1_2) * cast[int64](f8)
  var f1f9_76 = cast[int64](f1_2) * cast[int64](f9_38)
  var f2f2 = cast[int64](f2) * cast[int64](f2)
  var f2f3_2 = cast[int64](f2_2) * cast[int64](f3)
  var f2f4_2 = cast[int64](f2_2) * cast[int64](f4)
  var f2f5_2 = cast[int64](f2_2) * cast[int64](f5)
  var f2f6_2 = cast[int64](f2_2) * cast[int64](f6)
  var f2f7_2 = cast[int64](f2_2) * cast[int64](f7)
  var f2f8_38 = cast[int64](f2_2) * cast[int64](f8_19)
  var f2f9_38 = cast[int64](f2) * cast[int64](f9_38)
  var f3f3_2 = cast[int64](f3_2) * cast[int64](f3)
  var f3f4_2 = cast[int64](f3_2) * cast[int64](f4)
  var f3f5_4 = cast[int64](f3_2) * cast[int64](f5_2)
  var f3f6_2 = cast[int64](f3_2) * cast[int64](f6)
  var f3f7_76 = cast[int64](f3_2) * cast[int64](f7_38)
  var f3f8_38 = cast[int64](f3_2) * cast[int64](f8_19)
  var f3f9_76 = cast[int64](f3_2) * cast[int64](f9_38)
  var f4f4 = cast[int64](f4) * cast[int64](f4)
  var f4f5_2 = cast[int64](f4_2) * cast[int64](f5)
  var f4f6_38 = cast[int64](f4_2) * cast[int64](f6_19)
  var f4f7_38 = cast[int64](f4) * cast[int64](f7_38)
  var f4f8_38 = cast[int64](f4_2) * cast[int64](f8_19)
  var f4f9_38 = cast[int64](f4) * cast[int64](f9_38)
  var f5f5_38 = cast[int64](f5) * cast[int64](f5_38)
  var f5f6_38 = cast[int64](f5_2) * cast[int64](f6_19)
  var f5f7_76 = cast[int64](f5_2) * cast[int64](f7_38)
  var f5f8_38 = cast[int64](f5_2) * cast[int64](f8_19)
  var f5f9_76 = cast[int64](f5_2) * cast[int64](f9_38)
  var f6f6_19 = cast[int64](f6) * cast[int64](f6_19)
  var f6f7_38 = cast[int64](f6) * cast[int64](f7_38)
  var f6f8_38 = cast[int64](f6_2) * cast[int64](f8_19)
  var f6f9_38 = cast[int64](f6) * cast[int64](f9_38)
  var f7f7_38 = cast[int64](f7) * cast[int64](f7_38)
  var f7f8_38 = cast[int64](f7_2) * cast[int64](f8_19)
  var f7f9_76 = cast[int64](f7_2) * cast[int64](f9_38)
  var f8f8_19 = cast[int64](f8) * cast[int64](f8_19)
  var f8f9_38 = cast[int64](f8) * cast[int64](f9_38)
  var f9f9_38 = cast[int64](f9) * cast[int64](f9_38)
  var
    c0, c1, c2, c3, c4, c5, c6, c7, c8, c9: int64
    h0: int64 = f0f0 + f1f9_76 + f2f8_38 + f3f7_76 + f4f6_38 + f5f5_38
    h1: int64 = f0f1_2 + f2f9_38 + f3f8_38 + f4f7_38 + f5f6_38
    h2: int64 = f0f2_2 + f1f1_2 + f3f9_76 + f4f8_38 + f5f7_76 + f6f6_19
    h3: int64 = f0f3_2 + f1f2_2 + f4f9_38 + f5f8_38 + f6f7_38
    h4: int64 = f0f4_2 + f1f3_4 + f2f2 + f5f9_76 + f6f8_38 + f7f7_38
    h5: int64 = f0f5_2 + f1f4_2 + f2f3_2 + f6f9_38 + f7f8_38
    h6: int64 = f0f6_2 + f1f5_4 + f2f4_2 + f3f3_2 + f7f9_76 + f8f8_19
    h7: int64 = f0f7_2 + f1f6_2 + f2f5_2 + f3f4_2 + f8f9_38
    h8: int64 = f0f8_2 + f1f7_4 + f2f6_2 + f3f5_4 + f4f4 + f9f9_38
    h9: int64 = f0f9_2 + f1f8_2 + f2f7_2 + f3f6_2 + f4f5_2

  h0 += h0; h1 += h1; h2 += h2; h3 += h3; h4 += h4;
  h5 += h5; h6 += h6; h7 += h7; h8 += h8; h9 += h9;

  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 += c0; h0 -= c0 shl 26
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 += c4; h4 -= c4 shl 26
  c1 = ashr((h1 + (1'i64 shl 24)), 25); h2 += c1; h1 -= c1 shl 25
  c5 = ashr((h5 + (1'i64 shl 24)), 25); h6 += c5; h5 -= c5 shl 25
  c2 = ashr((h2 + (1'i64 shl 25)), 26); h3 += c2; h2 -= c2 shl 26
  c6 = ashr((h6 + (1'i64 shl 25)), 26); h7 += c6; h6 -= c6 shl 26
  c3 = ashr((h3 + (1'i64 shl 24)), 25); h4 += c3; h3 -= c3 shl 25
  c7 = ashr((h7 + (1'i64 shl 24)), 25); h8 += c7; h7 -= c7 shl 25
  c4 = ashr((h4 + (1'i64 shl 25)), 26); h5 += c4; h4 -= c4 shl 26
  c8 = ashr((h8 + (1'i64 shl 25)), 26); h9 += c8; h8 -= c8 shl 26
  c9 = ashr((h9 + (1'i64 shl 24)), 25); h0 += c9 * 19; h9 -= c9 shl 25
  c0 = ashr((h0 + (1'i64 shl 25)), 26); h1 += c0; h0 -= c0 shl 26

  h[0] = cast[int32](h0)
  h[1] = cast[int32](h1)
  h[2] = cast[int32](h2)
  h[3] = cast[int32](h3)
  h[4] = cast[int32](h4)
  h[5] = cast[int32](h5)
  h[6] = cast[int32](h6)
  h[7] = cast[int32](h7)
  h[8] = cast[int32](h8)
  h[9] = cast[int32](h9)

proc feInvert(outfe: var Fe, z: Fe) =
  var t0, t1, t2, t3: Fe
  feSq(t0, z)
  for i in 1..<1: feSq(t0, t0)
  feSq(t1, t0)
  for i in 1..<2: feSq(t1, t1)
  feMul(t1, z, t1)
  feMul(t0, t0, t1)
  feSq(t2, t0)
  for i in 1..<1: feSq(t2, t2)
  feMul(t1, t1, t2)
  feSq(t2, t1)
  for i in 1..<5: feSq(t2, t2)
  feMul(t1, t2, t1)
  feSq(t2, t1)
  for i in 1..<10: feSq(t2, t2)
  feMul(t2, t2, t1)
  feSq(t3, t2)
  for i in 1..<20: feSq(t3, t3)
  feMul(t2, t3, t2)
  feSq(t2, t2)
  for i in 1..<10: feSq(t2, t2)
  feMul(t1, t2, t1)
  feSq(t2, t1)
  for i in 1..<50: feSq(t2, t2)
  feMul(t2, t2, t1)
  feSq(t3, t2)
  for i in 1..<100: feSq(t3, t3)
  feMul(t2, t3, t2)
  feSq(t2, t2)
  for i in 1..<50: feSq(t2, t2)
  feMul(t1, t2, t1)
  feSq(t1, t1)
  for i in 1..<5: feSq(t1, t1)
  feMul(outfe, t1, t0)

proc fePow22523(outfe: var Fe, z: Fe) =
  var t0, t1, t2: Fe
  feSq(t0, z)
  for i in 1..<1: feSq(t0, t0)
  feSq(t1, t0)
  for i in 1..<2: feSq(t1, t1)
  feMul(t1, z, t1)
  feMul(t0, t0, t1)
  feSq(t0, t0)
  for i in 1..<1: feSq(t0, t0)
  feMul(t0, t1, t0)
  feSq(t1, t0)
  for i in 1..<5: feSq(t1, t1)
  feMul(t0, t1, t0)
  feSq(t1, t0)
  for i in 1..<10: feSq(t1, t1)
  feMul(t1, t1, t0)
  feSq(t2, t1)
  for i in 1..<20: feSq(t2, t2)
  feMul(t1, t2, t1)
  feSq(t1, t1)
  for i in 1..<10: feSq(t1, t1)
  feMul(t0, t1, t0)
  feSq(t1, t0)
  for i in 1..<50: feSq(t1, t1)
  feMul(t1, t1, t0)
  feSq(t2, t1)
  for i in 1..<100: feSq(t2, t2)
  feMul(t1, t2, t1)
  feSq(t1, t1)
  for i in 1..<50: feSq(t1, t1)
  feMul(t0, t1, t0)
  feSq(t0, t0)
  for i in 1..<2: feSq(t0, t0)
  feMul(outfe, t0, z)

proc geAdd(r: var GeP1P1, p: GeP3, q: GeCached) =
  var t0: Fe
  feAdd(r.x, p.y, p.x)
  feSub(r.y, p.y, p.x)
  feMul(r.z, r.x, q.yplusx)
  feMul(r.y, r.y, q.yminusx)
  feMul(r.t, q.t2d, p.t)
  feMul(r.x, p.z, q.z)
  feAdd(t0,r.x, r.x)
  feSub(r.x, r.z, r.y)
  feAdd(r.y, r.z, r.y)
  feAdd(r.z, t0, r.t)
  feSub(r.t, t0, r.t)

proc geFromBytesNegateVartime(h: var GeP3, s: openArray[byte]): int32 =
  var u, v, v3, vxx, check: Fe

  feFromBytes(h.y, s)
  fe1(h.z)
  feSq(u, h.y)

  feMul(v, u, DConst)
  feSub(u, u, h.z)
  feAdd(v, v, h.z)

  feSq(v3, v)
  feMul(v3, v3, v)
  feSq(h.x, v3)
  feMul(h.x, h.x, v)
  feMul(h.x, h.x, u)

  fePow22523(h.x, h.x)
  feMul(h.x, h.x, v3)
  feMul(h.x, h.x, u)

  feSq(vxx, h.x)
  feMul(vxx, vxx, v)
  feSub(check, vxx, u)
  if feIsNonZero(check) != 0:
    feAdd(check, vxx, u)
    if feIsNonZero(check) != 0:
      return -1;
    feMul(h.x, h.x, SqrTm1)

  if feIsNegative(h.x) == cast[int32](s[31] shr 7):
    feNeg(h.x, h.x)

  feMul(h.t, h.x, h.y)
  return 0

proc geMadd(r: var GeP1P1, p: GeP3, q: GePrecomp) =
  var t0: Fe
  feAdd(r.x, p.y, p.x)
  feSub(r.y, p.y, p.x)
  feMul(r.z, r.x, q.yplusx)
  feMul(r.y, r.y, q.yminusx)
  feMul(r.t, q.xy2d, p.t)
  feAdd(t0, p.z, p.z)
  feSub(r.x, r.z, r.y)
  feAdd(r.y, r.z, r.y)
  feAdd(r.z, t0, r.t)
  feSub(r.t, t0, r.t)

proc geMsub(r: var GeP1P1, p: GeP3, q: GePrecomp) =
  var t0: Fe
  feAdd(r.x, p.y, p.x)
  feSub(r.y, p.y, p.x)
  feMul(r.z, r.x, q.yminusx)
  feMul(r.y, r.y, q.yplusx)
  feMul(r.t, q.xy2d, p.t)
  feAdd(t0, p.z, p.z)
  feSub(r.x, r.z, r.y)
  feAdd(r.y, r.z, r.y)
  feSub(r.z, t0, r.t)
  feAdd(r.t, t0, r.t)

proc geSub(r: var GeP1P1, p: GeP3, q: GeCached) =
  var t0: Fe
  feAdd(r.x, p.y, p.x)
  feSub(r.y, p.y, p.x)
  feMul(r.z, r.x, q.yminusx)
  feMul(r.y, r.y, q.yplusx)
  feMul(r.t, q.t2d, p.t)
  feMul(r.x, p.z, q.z)
  feAdd(t0, r.x, r.x)
  feSub(r.x, r.z, r.y)
  feAdd(r.y, r.z, r.y)
  feSub(r.z, t0, r.t)
  feAdd(r.t, t0, r.t)

proc geToBytes(s: var openArray[byte], h: GeP2) =
  var recip, x, y: Fe
  feInvert(recip, h.z)
  feMul(x, h.x, recip)
  feMul(y, h.y, recip)
  feToBytes(s, y)
  s[31] = s[31] xor cast[byte](feIsNegative(x) shl 7)

proc geP1P1toP2(r: var GeP2, p: GeP1P1) =
  feMul(r.x, p.x, p.t)
  feMul(r.y, p.y, p.z)
  feMul(r.z, p.z, p.t)

proc geP1P1toP3(r: var GeP3, p: GeP1P1) =
  feMul(r.x, p.x, p.t)
  feMul(r.y, p.y, p.z)
  feMul(r.z, p.z, p.t)
  feMul(r.t, p.x, p.y)

proc geP20(h: var GeP2) =
  fe0(h.x)
  fe1(h.y)
  fe1(h.z)

proc geP2dbl(r: var GeP1P1, p: GeP2) =
  var t0: Fe
  feSq(r.x, p.x)
  feSq(r.z, p.y)
  feSq2(r.t, p.z)
  feAdd(r.y, p.x, p.y)
  feSq(t0, r.y)
  feAdd(r.y, r.z, r.x)
  feSub(r.z, r.z, r.x)
  feSub(r.x, t0, r.y)
  feSub(r.t, r.t, r.z)

proc geP30(h: var GeP3) =
  fe0(h.x)
  fe1(h.y)
  fe1(h.z)
  fe0(h.t)

proc geP3toP2(r: var GeP2, p: GeP3) =
  feCopy(r.x, p.x)
  feCopy(r.y, p.y)
  feCopy(r.z, p.z)

proc geP3dbl(r: var GeP1P1, p: GeP3) =
  var q: GeP2
  geP3toP2(q, p)
  geP2dbl(r, q)

proc geP3ToBytes(s: var openArray[byte], h: GeP3) =
  var recip, x, y: Fe

  feInvert(recip, h.z);
  feMul(x, h.x, recip);
  feMul(y, h.y, recip);
  feToBytes(s, y);
  s[31] = s[31] xor cast[byte](feIsNegative(x) shl 7)

proc geP3ToCached(r: var GeCached, p: GeP3) =
  feAdd(r.yplusx, p.y, p.x)
  feSub(r.yminusx, p.y, p.x)
  feCopy(r.z, p.z)
  feMul(r.t2d, p.t, D2Const)

proc gePrecomp0(h: var GePrecomp) =
  fe1(h.yplusx)
  fe1(h.yminusx)
  fe0(h.xy2d)

proc equal(b, c: int8): byte =
  var ub = cast[byte](b)
  var uc = cast[byte](c)
  var x = ub xor uc
  var y = cast[uint32](x)
  y = y - 1
  y = y shr 31
  result = cast[byte](y)

proc negative(b: int8): byte =
  var x = cast[uint64](b)
  x = x shr 63
  result = cast[byte](x)

proc cmov(t: var GePrecomp, u: GePrecomp, b: byte) =
  feCmov(t.yplusx, u.yplusx, b)
  feCmov(t.yminusx, u.yminusx, b)
  feCmov(t.xy2d, u.xy2d, b)

proc select(t: var GePrecomp, pos: int, b: int8) =
  var minust: GePrecomp
  var bnegative = negative(b)
  var babs = cast[uint8](b) - (((-bnegative) and cast[uint8](b)) shl 1)
  gePrecomp0(t)
  cmov(t, BasePrecomp[pos][0], equal(cast[int8](babs), 1'i8))
  cmov(t, BasePrecomp[pos][1], equal(cast[int8](babs), 2'i8))
  cmov(t, BasePrecomp[pos][2], equal(cast[int8](babs), 3'i8))
  cmov(t, BasePrecomp[pos][3], equal(cast[int8](babs), 4'i8))
  cmov(t, BasePrecomp[pos][4], equal(cast[int8](babs), 5'i8))
  cmov(t, BasePrecomp[pos][5], equal(cast[int8](babs), 6'i8))
  cmov(t, BasePrecomp[pos][6], equal(cast[int8](babs), 7'i8))
  cmov(t, BasePrecomp[pos][7], equal(cast[int8](babs), 8'i8))
  feCopy(minust.yplusx, t.yminusx)
  feCopy(minust.yminusx, t.yplusx)
  feNeg(minust.xy2d, t.xy2d)
  cmov(t, minust, bnegative)

proc geScalarMultBase(h: var GeP3, a: openArray[byte]) =
  var e: array[64, int8]
  var carry: int8
  var r: GeP1P1
  var s: GeP2
  var t: GePrecomp

  for i in 0..<32:
    e[2 * i + 0] = cast[int8]((a[i] shr 0) and 15)
    e[2 * i + 1] = cast[int8]((a[i] shr 4) and 15)

  carry = 0
  for i in 0..<63:
    e[i] += carry
    carry = e[i] + 8
    carry = carry shr 4
    e[i] -= carry shl 4

  e[63] += carry
  geP30(h)
  for i in countup(1, 63, 2):
    select(t, i div 2, e[i])
    geMadd(r, h, t)
    geP1P1toP3(h, r)

  geP3dbl(r, h); geP1P1toP2(s, r)
  geP2dbl(r, s); geP1P1toP2(s, r)
  geP2dbl(r, s); geP1P1toP2(s, r)
  geP2dbl(r, s); geP1P1toP3(h, r)

  for i in countup(0, 63, 2):
    select(t, i div 2, e[i])
    geMadd(r, h, t)
    geP1P1toP3(h, r)

proc scMulAdd(s: var openArray[byte], a, b, c: openArray[byte]) =
  var a0 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(0, 2)))
  var a1 = 2097151'i64 and cast[int64](load_4(a.toOpenArray(2, 5)) shr 5)
  var a2 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(5, 7)) shr 2)
  var a3 = 2097151'i64 and cast[int64](load_4(a.toOpenArray(7, 10)) shr 7)
  var a4 = 2097151'i64 and cast[int64](load_4(a.toOpenArray(10, 13)) shr 4)
  var a5 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(13, 15)) shr 1)
  var a6 = 2097151'i64 and cast[int64](load_4(a.toOpenArray(15, 18)) shr 6)
  var a7 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(18, 20)) shr 3)
  var a8 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(21, 23)))
  var a9 = 2097151'i64 and cast[int64](load_4(a.toOpenArray(23, 26)) shr 5)
  var a10 = 2097151'i64 and cast[int64](load_3(a.toOpenArray(26, 28)) shr 2)
  var a11 = cast[int64](load_4(a.toOpenArray(28, 31)) shr 7)
  var b0 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(0, 2)))
  var b1 = 2097151'i64 and cast[int64](load_4(b.toOpenArray(2, 5)) shr 5)
  var b2 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(5, 7)) shr 2)
  var b3 = 2097151'i64 and cast[int64](load_4(b.toOpenArray(7, 10)) shr 7)
  var b4 = 2097151'i64 and cast[int64](load_4(b.toOpenArray(10, 13)) shr 4)
  var b5 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(13, 15)) shr 1)
  var b6 = 2097151'i64 and cast[int64](load_4(b.toOpenArray(15, 18)) shr 6)
  var b7 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(18, 20)) shr 3)
  var b8 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(21, 23)))
  var b9 = 2097151'i64 and cast[int64](load_4(b.toOpenArray(23, 26)) shr 5)
  var b10 = 2097151'i64 and cast[int64](load_3(b.toOpenArray(26, 28)) shr 2)
  var b11 = cast[int64](load_4(b.toOpenArray(28, 31)) shr 7)
  var c0 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(0, 2)))
  var c1 = 2097151'i64 and cast[int64](load_4(c.toOpenArray(2, 5)) shr 5)
  var c2 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(5, 7)) shr 2)
  var c3 = 2097151'i64 and cast[int64](load_4(c.toOpenArray(7, 10)) shr 7)
  var c4 = 2097151'i64 and cast[int64](load_4(c.toOpenArray(10, 13)) shr 4)
  var c5 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(13, 15)) shr 1)
  var c6 = 2097151'i64 and cast[int64](load_4(c.toOpenArray(15, 18)) shr 6)
  var c7 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(18, 20)) shr 3)
  var c8 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(21, 23)))
  var c9 = 2097151'i64 and cast[int64](load_4(c.toOpenArray(23, 26)) shr 5)
  var c10 = 2097151'i64 and cast[int64](load_3(c.toOpenArray(26, 28)) shr 2)
  var c11 = cast[int64](load_4(c.toOpenArray(28, 31)) shr 7)
  var
    s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12: int64
    s13, s14, s15, s16, s17, s18, s19, s20, s21, s22, s23: int64
    cr0, cr1, cr2, cr3, cr4, cr5, cr6, cr7, cr8, cr9, cr10, cr11: int64
    cr12, cr13, cr14, cr15, cr16, cr17, cr18, cr19, cr20, cr21, cr22: int64

  s0 = c0 + a0 * b0
  s1 = c1 + a0 * b1 + a1 * b0
  s2 = c2 + a0 * b2 + a1 * b1 + a2 * b0
  s3 = c3 + a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
  s4 = c4 + a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0
  s5 = c5 + a0 * b5 + a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1 + a5 * b0
  s6 = c6 + a0 * b6 + a1 * b5 + a2 * b4 + a3 * b3 + a4 * b2 + a5 * b1 +
       a6 * b0
  s7 = c7 + a0 * b7 + a1 * b6 + a2 * b5 + a3 * b4 + a4 * b3 + a5 * b2 +
       a6 * b1 + a7 * b0
  s8 = c8 + a0 * b8 + a1 * b7 + a2 * b6 + a3 * b5 + a4 * b4 + a5 * b3 +
       a6 * b2 + a7 * b1 + a8 * b0
  s9 = c9 + a0 * b9 + a1 * b8 + a2 * b7 + a3 * b6 + a4 * b5 + a5 * b4 +
       a6 * b3 + a7 * b2 + a8 * b1 + a9 * b0
  s10 = c10 + a0 * b10 + a1 * b9 + a2 * b8 + a3 * b7 + a4 * b6 + a5 * b5 +
       a6 * b4 + a7 * b3 + a8 * b2 + a9 * b1 + a10 * b0
  s11 = c11 + a0 * b11 + a1 * b10 + a2 * b9 + a3 * b8 + a4 * b7 + a5 * b6 +
        a6 * b5 + a7 * b4 + a8 * b3 + a9 * b2 + a10 * b1 + a11 * b0
  s12 = a1 * b11 + a2 * b10 + a3 * b9 + a4 * b8 + a5 * b7 + a6 * b6 + a7 * b5 +
        a8 * b4 + a9 * b3 + a10 * b2 + a11 * b1
  s13 = a2 * b11 + a3 * b10 + a4 * b9 + a5 * b8 + a6 * b7 + a7 * b6 + a8 * b5 +
        a9 * b4 + a10 * b3 + a11 * b2
  s14 = a3 * b11 + a4 * b10 + a5 * b9 + a6 * b8 + a7 * b7 + a8 * b6 + a9 * b5 +
        a10 * b4 + a11 * b3
  s15 = a4 * b11 + a5 * b10 + a6 * b9 + a7 * b8 + a8 * b7 + a9 * b6 + a10 * b5 +
        a11 * b4
  s16 = a5 * b11 + a6 * b10 + a7 * b9 + a8 * b8 + a9 * b7 + a10 * b6 + a11 * b5
  s17 = a6 * b11 + a7 * b10 + a8 * b9 + a9 * b8 + a10 * b7 + a11 * b6
  s18 = a7 * b11 + a8 * b10 + a9 * b9 + a10 * b8 + a11 * b7
  s19 = a8 * b11 + a9 * b10 + a10 * b9 + a11 * b8
  s20 = a9 * b11 + a10 * b10 + a11 * b9
  s21 = a10 * b11 + a11 * b10
  s22 = a11 * b11
  s23 = 0

  cr0 = ashr((s0 + (1'i64 shl 20)), 21); s1 += cr0; s0 -= cr0 shl 21
  cr2 = ashr((s2 + (1'i64 shl 20)), 21); s3 += cr2; s2 -= cr2 shl 21
  cr4 = ashr((s4 + (1'i64 shl 20)), 21); s5 += cr4; s4 -= cr4 shl 21
  cr6 = ashr((s6 + (1'i64 shl 20)), 21); s7 += cr6; s6 -= cr6 shl 21
  cr8 = ashr((s8 + (1'i64 shl 20)), 21); s9 += cr8; s8 -= cr8 shl 21
  cr10 = ashr((s10 + (1'i64 shl 20)), 21); s11 += cr10; s10 -= cr10 shl 21
  cr12 = ashr((s12 + (1'i64 shl 20)), 21); s13 += cr12; s12 -= cr12 shl 21
  cr14 = ashr((s14 + (1'i64 shl 20)), 21); s15 += cr14; s14 -= cr14 shl 21
  cr16 = ashr((s16 + (1'i64 shl 20)), 21); s17 += cr16; s16 -= cr16 shl 21
  cr18 = ashr((s18 + (1'i64 shl 20)), 21); s19 += cr18; s18 -= cr18 shl 21
  cr20 = ashr((s20 + (1'i64 shl 20)), 21); s21 += cr20; s20 -= cr20 shl 21
  cr22 = ashr((s22 + (1'i64 shl 20)), 21); s23 += cr22; s22 -= cr22 shl 21

  cr1 = ashr((s1 + (1'i64 shl 20)), 21); s2 += cr1; s1 -= cr1 shl 21
  cr3 = ashr((s3 + (1'i64 shl 20)), 21); s4 += cr3; s3 -= cr3 shl 21
  cr5 = ashr((s5 + (1'i64 shl 20)), 21); s6 += cr5; s5 -= cr5 shl 21
  cr7 = ashr((s7 + (1'i64 shl 20)), 21); s8 += cr7; s7 -= cr7 shl 21
  cr9 = ashr((s9 + (1'i64 shl 20)), 21); s10 += cr9; s9 -= cr9 shl 21
  cr11 = ashr((s11 + (1'i64 shl 20)), 21); s12 += cr11; s11 -= cr11 shl 21
  cr13 = ashr((s13 + (1'i64 shl 20)), 21); s14 += cr13; s13 -= cr13 shl 21
  cr15 = ashr((s15 + (1'i64 shl 20)), 21); s16 += cr15; s15 -= cr15 shl 21
  cr17 = ashr((s17 + (1'i64 shl 20)), 21); s18 += cr17; s17 -= cr17 shl 21
  cr19 = ashr((s19 + (1'i64 shl 20)), 21); s20 += cr19; s19 -= cr19 shl 21
  cr21 = ashr((s21 + (1'i64 shl 20)), 21); s22 += cr21; s21 -= cr21 shl 21

  s11 += s23 * 666643
  s12 += s23 * 470296
  s13 += s23 * 654183
  s14 -= s23 * 997805
  s15 += s23 * 136657
  s16 -= s23 * 683901
  s23 = 0

  s10 += s22 * 666643
  s11 += s22 * 470296
  s12 += s22 * 654183
  s13 -= s22 * 997805
  s14 += s22 * 136657
  s15 -= s22 * 683901
  s22 = 0

  s9 += s21 * 666643
  s10 += s21 * 470296
  s11 += s21 * 654183
  s12 -= s21 * 997805
  s13 += s21 * 136657
  s14 -= s21 * 683901
  s21 = 0

  s8 += s20 * 666643
  s9 += s20 * 470296
  s10 += s20 * 654183
  s11 -= s20 * 997805
  s12 += s20 * 136657
  s13 -= s20 * 683901
  s20 = 0

  s7 += s19 * 666643
  s8 += s19 * 470296
  s9 += s19 * 654183
  s10 -= s19 * 997805
  s11 += s19 * 136657
  s12 -= s19 * 683901
  s19 = 0

  s6 += s18 * 666643
  s7 += s18 * 470296
  s8 += s18 * 654183
  s9 -= s18 * 997805
  s10 += s18 * 136657
  s11 -= s18 * 683901
  s18 = 0

  cr6 = ashr((s6 + (1'i64 shl 20)), 21); s7 += cr6; s6 -= cr6 shl 21
  cr8 = ashr((s8 + (1'i64 shl 20)), 21); s9 += cr8; s8 -= cr8 shl 21
  cr10 = ashr((s10 + (1'i64 shl 20)), 21); s11 += cr10; s10 -= cr10 shl 21
  cr12 = ashr((s12 + (1'i64 shl 20)), 21); s13 += cr12; s12 -= cr12 shl 21
  cr14 = ashr((s14 + (1'i64 shl 20)), 21); s15 += cr14; s14 -= cr14 shl 21
  cr16 = ashr((s16 + (1'i64 shl 20)), 21); s17 += cr16; s16 -= cr16 shl 21

  cr7 = ashr((s7 + (1'i64 shl 20)), 21); s8 += cr7; s7 -= cr7 shl 21
  cr9 = ashr((s9 + (1'i64 shl 20)), 21); s10 += cr9; s9 -= cr9 shl 21
  cr11 = ashr((s11 + (1'i64 shl 20)), 21); s12 += cr11; s11 -= cr11 shl 21
  cr13 = ashr((s13 + (1'i64 shl 20)), 21); s14 += cr13; s13 -= cr13 shl 21
  cr15 = ashr((s15 + (1'i64 shl 20)), 21); s16 += cr15; s15 -= cr15 shl 21

  s5 += s17 * 666643
  s6 += s17 * 470296
  s7 += s17 * 654183
  s8 -= s17 * 997805
  s9 += s17 * 136657
  s10 -= s17 * 683901
  s17 = 0

  s4 += s16 * 666643
  s5 += s16 * 470296
  s6 += s16 * 654183
  s7 -= s16 * 997805
  s8 += s16 * 136657
  s9 -= s16 * 683901
  s16 = 0

  s3 += s15 * 666643
  s4 += s15 * 470296
  s5 += s15 * 654183
  s6 -= s15 * 997805
  s7 += s15 * 136657
  s8 -= s15 * 683901
  s15 = 0

  s2 += s14 * 666643
  s3 += s14 * 470296
  s4 += s14 * 654183
  s5 -= s14 * 997805
  s6 += s14 * 136657
  s7 -= s14 * 683901
  s14 = 0

  s1 += s13 * 666643
  s2 += s13 * 470296
  s3 += s13 * 654183
  s4 -= s13 * 997805
  s5 += s13 * 136657
  s6 -= s13 * 683901
  s13 = 0

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0

  cr0 = ashr((s0 + (1'i64 shl 20)), 21); s1 += cr0; s0 -= cr0 shl 21
  cr2 = ashr((s2 + (1'i64 shl 20)), 21); s3 += cr2; s2 -= cr2 shl 21
  cr4 = ashr((s4 + (1'i64 shl 20)), 21); s5 += cr4; s4 -= cr4 shl 21
  cr6 = ashr((s6 + (1'i64 shl 20)), 21); s7 += cr6; s6 -= cr6 shl 21
  cr8 = ashr((s8 + (1'i64 shl 20)), 21); s9 += cr8; s8 -= cr8 shl 21
  cr10 = ashr((s10 + (1'i64 shl 20)), 21); s11 += cr10; s10 -= cr10 shl 21

  cr1 = ashr((s1 + (1'i64 shl 20)), 21); s2 += cr1; s1 -= cr1 shl 21
  cr3 = ashr((s3 + (1'i64 shl 20)), 21); s4 += cr3; s3 -= cr3 shl 21
  cr5 = ashr((s5 + (1'i64 shl 20)), 21); s6 += cr5; s5 -= cr5 shl 21
  cr7 = ashr((s7 + (1'i64 shl 20)), 21); s8 += cr7; s7 -= cr7 shl 21
  cr9 = ashr((s9 + (1'i64 shl 20)), 21); s10 += cr9; s9 -= cr9 shl 21
  cr11 = ashr((s11 + (1'i64 shl 20)), 21); s12 += cr11; s11 -= cr11 shl 21

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0

  cr0 = ashr(s0, 21); s1 += cr0; s0 -= cr0 shl 21
  cr1 = ashr(s1, 21); s2 += cr1; s1 -= cr1 shl 21
  cr2 = ashr(s2, 21); s3 += cr2; s2 -= cr2 shl 21
  cr3 = ashr(s3, 21); s4 += cr3; s3 -= cr3 shl 21
  cr4 = ashr(s4, 21); s5 += cr4; s4 -= cr4 shl 21
  cr5 = ashr(s5, 21); s6 += cr5; s5 -= cr5 shl 21
  cr6 = ashr(s6, 21); s7 += cr6; s6 -= cr6 shl 21
  cr7 = ashr(s7, 21); s8 += cr7; s7 -= cr7 shl 21
  cr8 = ashr(s8, 21); s9 += cr8; s8 -= cr8 shl 21
  cr9 = ashr(s9, 21); s10 += cr9; s9 -= cr9 shl 21
  cr10 = ashr(s10, 21); s11 += cr10; s10 -= cr10 shl 21
  cr11 = ashr(s11, 21); s12 += cr11; s11 -= cr11 shl 21

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0

  cr0 = ashr(s0, 21); s1 += cr0; s0 -= cr0 shl 21
  cr1 = ashr(s1, 21); s2 += cr1; s1 -= cr1 shl 21
  cr2 = ashr(s2, 21); s3 += cr2; s2 -= cr2 shl 21
  cr3 = ashr(s3, 21); s4 += cr3; s3 -= cr3 shl 21
  cr4 = ashr(s4, 21); s5 += cr4; s4 -= cr4 shl 21
  cr5 = ashr(s5, 21); s6 += cr5; s5 -= cr5 shl 21
  cr6 = ashr(s6, 21); s7 += cr6; s6 -= cr6 shl 21
  cr7 = ashr(s7, 21); s8 += cr7; s7 -= cr7 shl 21
  cr8 = ashr(s8, 21); s9 += cr8; s8 -= cr8 shl 21
  cr9 = ashr(s9, 21); s10 += cr9; s9 -= cr9 shl 21
  cr10 = ashr(s10, 21); s11 += cr10; s10 -= cr10 shl 21

  s[0] = cast[uint8](ashr(s0, 0))
  s[1] = cast[uint8](ashr(s0, 8))
  s[2] = cast[uint8](ashr(s0, 16) or (s1 shl 5))
  s[3] = cast[uint8](ashr(s1, 3))
  s[4] = cast[uint8](ashr(s1, 11))
  s[5] = cast[uint8](ashr(s1, 19) or (s2 shl 2))
  s[6] = cast[uint8](ashr(s2, 6))
  s[7] = cast[uint8](ashr(s2, 14) or (s3 shl 7))
  s[8] = cast[uint8](ashr(s3, 1))
  s[9] = cast[uint8](ashr(s3, 9))
  s[10] = cast[uint8](ashr(s3, 17) or (s4 shl 4))
  s[11] = cast[uint8](ashr(s4, 4))
  s[12] = cast[uint8](ashr(s4, 12))
  s[13] = cast[uint8](ashr(s4, 20) or (s5 shl 1))
  s[14] = cast[uint8](ashr(s5, 7))
  s[15] = cast[uint8](ashr(s5, 15) or (s6 shl 6))
  s[16] = cast[uint8](ashr(s6, 2))
  s[17] = cast[uint8](ashr(s6, 10))
  s[18] = cast[uint8](ashr(s6, 18) or (s7 shl 3))
  s[19] = cast[uint8](ashr(s7, 5))
  s[20] = cast[uint8](ashr(s7, 13))
  s[21] = cast[uint8](ashr(s8, 0))
  s[22] = cast[uint8](ashr(s8, 8))
  s[23] = cast[uint8](ashr(s8, 16) or (s9 shl 5))
  s[24] = cast[uint8](ashr(s9, 3))
  s[25] = cast[uint8](ashr(s9, 11))
  s[26] = cast[uint8](ashr(s9, 19) or (s10 shl 2))
  s[27] = cast[uint8](ashr(s10, 6))
  s[28] = cast[uint8](ashr(s10, 14) or (s11 shl 7))
  s[29] = cast[uint8](ashr(s11, 1))
  s[30] = cast[uint8](ashr(s11, 9))
  s[31] = cast[uint8](ashr(s11, 17))

proc scReduce(s: var openArray[byte]) =
  var s0 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(0, 2)));
  var s1 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(2, 5)) shr 5)
  var s2 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(5, 7)) shr 2)
  var s3 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(7, 10)) shr 7)
  var s4 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(10, 13)) shr 4)
  var s5 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(13, 15)) shr 1)
  var s6 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(15, 18)) shr 6)
  var s7 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(18, 20)) shr 3)
  var s8 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(21, 23)))
  var s9 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(23, 26)) shr 5)
  var s10 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(26, 28)) shr 2)
  var s11 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(28, 31)) shr 7)
  var s12 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(31, 34)) shr 4)
  var s13 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(34, 36)) shr 1)
  var s14 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(36, 39)) shr 6)
  var s15 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(39, 42)) shr 3)
  var s16 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(42, 44)))
  var s17 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(44, 47)) shr 5)
  var s18 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(47, 49)) shr 2)
  var s19 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(49, 52)) shr 7)
  var s20 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(52, 55)) shr 4)
  var s21 = 2097151'i64 and cast[int64](load_3(s.toOpenArray(55, 57)) shr 1)
  var s22 = 2097151'i64 and cast[int64](load_4(s.toOpenArray(57, 60)) shr 6)
  var s23 = cast[int64](load_4(s.toOpenArray(60, 63)) shr 3)
  var
    cr0, cr1, cr2, cr3, cr4, cr5, cr6, cr7, cr8: int64
    cr9, cr10, cr11, cr12, cr13, cr14, cr15, cr16: int64

  s11 += s23 * 666643
  s12 += s23 * 470296
  s13 += s23 * 654183
  s14 -= s23 * 997805
  s15 += s23 * 136657
  s16 -= s23 * 683901
  s23 = 0

  s10 += s22 * 666643
  s11 += s22 * 470296
  s12 += s22 * 654183
  s13 -= s22 * 997805
  s14 += s22 * 136657
  s15 -= s22 * 683901
  s22 = 0

  s9 += s21 * 666643
  s10 += s21 * 470296
  s11 += s21 * 654183
  s12 -= s21 * 997805
  s13 += s21 * 136657
  s14 -= s21 * 683901
  s21 = 0

  s8 += s20 * 666643
  s9 += s20 * 470296
  s10 += s20 * 654183
  s11 -= s20 * 997805
  s12 += s20 * 136657
  s13 -= s20 * 683901
  s20 = 0

  s7 += s19 * 666643
  s8 += s19 * 470296
  s9 += s19 * 654183
  s10 -= s19 * 997805
  s11 += s19 * 136657
  s12 -= s19 * 683901
  s19 = 0

  s6 += s18 * 666643
  s7 += s18 * 470296
  s8 += s18 * 654183
  s9 -= s18 * 997805
  s10 += s18 * 136657
  s11 -= s18 * 683901
  s18 = 0

  cr6 = ashr((s6 + (1'i64 shl 20)), 21); s7 += cr6; s6 -= cr6 shl 21
  cr8 = ashr((s8 + (1'i64 shl 20)), 21); s9 += cr8; s8 -= cr8 shl 21
  cr10 = ashr((s10 + (1'i64 shl 20)), 21); s11 += cr10; s10 -= cr10 shl 21
  cr12 = ashr((s12 + (1'i64 shl 20)), 21); s13 += cr12; s12 -= cr12 shl 21
  cr14 = ashr((s14 + (1'i64 shl 20)), 21); s15 += cr14; s14 -= cr14 shl 21
  cr16 = ashr((s16 + (1'i64 shl 20)), 21); s17 += cr16; s16 -= cr16 shl 21

  cr7 = ashr((s7 + (1'i64 shl 20)), 21); s8 += cr7; s7 -= cr7 shl 21
  cr9 = ashr((s9 + (1'i64 shl 20)), 21); s10 += cr9; s9 -= cr9 shl 21
  cr11 = ashr((s11 + (1'i64 shl 20)), 21); s12 += cr11; s11 -= cr11 shl 21
  cr13 = ashr((s13 + (1'i64 shl 20)), 21); s14 += cr13; s13 -= cr13 shl 21
  cr15 = ashr((s15 + (1'i64 shl 20)), 21); s16 += cr15; s15 -= cr15 shl 21

  s5 += s17 * 666643
  s6 += s17 * 470296
  s7 += s17 * 654183
  s8 -= s17 * 997805
  s9 += s17 * 136657
  s10 -= s17 * 683901
  s17 = 0

  s4 += s16 * 666643
  s5 += s16 * 470296
  s6 += s16 * 654183
  s7 -= s16 * 997805
  s8 += s16 * 136657
  s9 -= s16 * 683901
  s16 = 0

  s3 += s15 * 666643
  s4 += s15 * 470296
  s5 += s15 * 654183
  s6 -= s15 * 997805
  s7 += s15 * 136657
  s8 -= s15 * 683901
  s15 = 0

  s2 += s14 * 666643
  s3 += s14 * 470296
  s4 += s14 * 654183
  s5 -= s14 * 997805
  s6 += s14 * 136657
  s7 -= s14 * 683901
  s14 = 0

  s1 += s13 * 666643
  s2 += s13 * 470296
  s3 += s13 * 654183
  s4 -= s13 * 997805
  s5 += s13 * 136657
  s6 -= s13 * 683901
  s13 = 0

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0

  cr0 = ashr((s0 + (1'i64 shl 20)), 21); s1 += cr0; s0 -= cr0 shl 21
  cr2 = ashr((s2 + (1'i64 shl 20)), 21); s3 += cr2; s2 -= cr2 shl 21
  cr4 = ashr((s4 + (1'i64 shl 20)), 21); s5 += cr4; s4 -= cr4 shl 21
  cr6 = ashr((s6 + (1'i64 shl 20)), 21); s7 += cr6; s6 -= cr6 shl 21
  cr8 = ashr((s8 + (1'i64 shl 20)), 21); s9 += cr8; s8 -= cr8 shl 21
  cr10 = ashr((s10 + (1'i64 shl 20)), 21); s11 += cr10; s10 -= cr10 shl 21

  cr1 = ashr((s1 + (1'i64 shl 20)), 21); s2 += cr1; s1 -= cr1 shl 21
  cr3 = ashr((s3 + (1'i64 shl 20)), 21); s4 += cr3; s3 -= cr3 shl 21
  cr5 = ashr((s5 + (1'i64 shl 20)), 21); s6 += cr5; s5 -= cr5 shl 21
  cr7 = ashr((s7 + (1'i64 shl 20)), 21); s8 += cr7; s7 -= cr7 shl 21
  cr9 = ashr((s9 + (1'i64 shl 20)), 21); s10 += cr9; s9 -= cr9 shl 21
  cr11 = ashr((s11 + (1'i64 shl 20)), 21); s12 += cr11; s11 -= cr11 shl 21

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0;

  cr0 = ashr(s0, 21); s1 += cr0; s0 -= cr0 shl 21
  cr1 = ashr(s1, 21); s2 += cr1; s1 -= cr1 shl 21
  cr2 = ashr(s2, 21); s3 += cr2; s2 -= cr2 shl 21
  cr3 = ashr(s3, 21); s4 += cr3; s3 -= cr3 shl 21
  cr4 = ashr(s4, 21); s5 += cr4; s4 -= cr4 shl 21
  cr5 = ashr(s5, 21); s6 += cr5; s5 -= cr5 shl 21
  cr6 = ashr(s6, 21); s7 += cr6; s6 -= cr6 shl 21
  cr7 = ashr(s7, 21); s8 += cr7; s7 -= cr7 shl 21
  cr8 = ashr(s8, 21); s9 += cr8; s8 -= cr8 shl 21
  cr9 = ashr(s9, 21); s10 += cr9; s9 -= cr9 shl 21
  cr10 = ashr(s10, 21); s11 += cr10; s10 -= cr10 shl 21
  cr11 = ashr(s11, 21); s12 += cr11; s11 -= cr11 shl 21

  s0 += s12 * 666643
  s1 += s12 * 470296
  s2 += s12 * 654183
  s3 -= s12 * 997805
  s4 += s12 * 136657
  s5 -= s12 * 683901
  s12 = 0

  cr0 = ashr(s0, 21); s1 += cr0; s0 -= cr0 shl 21
  cr1 = ashr(s1, 21); s2 += cr1; s1 -= cr1 shl 21
  cr2 = ashr(s2, 21); s3 += cr2; s2 -= cr2 shl 21
  cr3 = ashr(s3, 21); s4 += cr3; s3 -= cr3 shl 21
  cr4 = ashr(s4, 21); s5 += cr4; s4 -= cr4 shl 21
  cr5 = ashr(s5, 21); s6 += cr5; s5 -= cr5 shl 21
  cr6 = ashr(s6, 21); s7 += cr6; s6 -= cr6 shl 21
  cr7 = ashr(s7, 21); s8 += cr7; s7 -= cr7 shl 21
  cr8 = ashr(s8, 21); s9 += cr8; s8 -= cr8 shl 21
  cr9 = ashr(s9, 21); s10 += cr9; s9 -= cr9 shl 21
  cr10 = ashr(s10, 21); s11 += cr10; s10 -= cr10 shl 21

  s[0] = cast[byte](ashr(s0, 0))
  s[1] = cast[byte](ashr(s0, 8))
  s[2] = cast[byte](ashr(s0, 16) or (s1 shl 5))
  s[3] = cast[byte](ashr(s1, 3))
  s[4] = cast[byte](ashr(s1, 11))
  s[5] = cast[byte](ashr(s1, 19) or (s2 shl 2))
  s[6] = cast[byte](ashr(s2, 6))
  s[7] = cast[byte](ashr(s2, 14) or (s3 shl 7))
  s[8] = cast[byte](ashr(s3, 1))
  s[9] = cast[byte](ashr(s3, 9))
  s[10] = cast[byte](ashr(s3, 17) or (s4 shl 4))
  s[11] = cast[byte](ashr(s4, 4))
  s[12] = cast[byte](ashr(s4, 12))
  s[13] = cast[byte](ashr(s4, 20) or (s5 shl 1))
  s[14] = cast[byte](ashr(s5, 7))
  s[15] = cast[byte](ashr(s5, 15) or (s6 shl 6))
  s[16] = cast[byte](ashr(s6, 2))
  s[17] = cast[byte](ashr(s6, 10))
  s[18] = cast[byte](ashr(s6, 18) or (s7 shl 3))
  s[19] = cast[byte](ashr(s7, 5))
  s[20] = cast[byte](ashr(s7, 13))
  s[21] = cast[byte](ashr(s8, 0))
  s[22] = cast[byte](ashr(s8, 8))
  s[23] = cast[byte](ashr(s8, 16) or (s9 shl 5))
  s[24] = cast[byte](ashr(s9, 3))
  s[25] = cast[byte](ashr(s9, 11))
  s[26] = cast[byte](ashr(s9, 19) or (s10 shl 2))
  s[27] = cast[byte](ashr(s10, 6))
  s[28] = cast[byte](ashr(s10, 14) or (s11 shl 7))
  s[29] = cast[byte](ashr(s11, 1))
  s[30] = cast[byte](ashr(s11, 9))
  s[31] = cast[byte](ashr(s11, 17))

proc slide(r: var openArray[int8], a: openArray[byte]) =
  for i in 0..<256:
    r[i] = cast[int8](1'u8 and (a[i shr 3] shr (i and 7)))
  for i in 0..<256:
    if r[i] != 0'i8:
      var b = 1
      while (b <= 6) and (i + b < 256):
        if r[i + b] != 0'i8:
          if r[i] + (r[i + b] shl b) <= 15:
            r[i] += r[i + b] shl b; r[i + b] = 0'i8
          elif (r[i] - (r[i + b] shl b)) >= -15:
            r[i] -= r[i + b] shl b
            for k in (i + b)..<256:
              if r[k] == 0'i8:
                r[k] = 1'i8
                break
              r[k] = 0'i8
          else:
            break
        inc(b)

proc geDoubleScalarMultVartime(r: var GeP2, a: openArray[byte], A: GeP3,
                               b: openArray[byte]) =
  var
    aslide: array[256, int8]
    bslide: array[256, int8]
    ai: array[8, GeCached]
    t: GeP1P1
    u: GeP3
    a2: GeP3

  slide(aslide, a)
  slide(bslide, b)

  geP3ToCached(ai[0], A)
  geP3dbl(t, A); geP1P1toP3(a2, t)
  geAdd(t, a2, ai[0]); geP1P1toP3(u, t); geP3ToCached(ai[1], u)
  geAdd(t, a2, ai[1]); geP1P1toP3(u, t); geP3ToCached(ai[2], u)
  geAdd(t, a2, ai[2]); geP1P1toP3(u, t); geP3ToCached(ai[3], u)
  geAdd(t, a2, ai[3]); geP1P1toP3(u, t); geP3ToCached(ai[4], u)
  geAdd(t, a2, ai[4]); geP1P1toP3(u, t); geP3ToCached(ai[5], u)
  geAdd(t, a2, ai[5]); geP1P1toP3(u, t); geP3ToCached(ai[6], u)
  geAdd(t, a2, ai[6]); geP1P1toP3(u, t); geP3ToCached(ai[7], u)
  geP20(r)

  var k = 255
  while k >= 0:
    if (aslide[k] != 0) or (bslide[k] != 0):
      break
    dec(k)

  while k >= 0:
    geP2dbl(t, r)
    if aslide[k] > 0:
      geP1P1toP3(u, t)
      geAdd(t, u, ai[aslide[k] div 2])
    elif aslide[k] < 0:
      geP1P1toP3(u, t)
      geSub(t, u, ai[(-aslide[k]) div 2])
    if bslide[k] > 0:
      geP1P1toP3(u, t)
      geMadd(t, u, BiPrecomp[bslide[k] div 2])
    elif bslide[k] < 0:
      geP1P1toP3(u, t)
      geMsub(t, u, BiPrecomp[(-bslide[k]) div 2])
    geP1P1toP2(r, t)
    dec(k)

proc GT(x, y: uint32): uint32 {.inline.} =
  var z = cast[uint32](y - x)
  result = (z xor ((x xor y) and (x xor z))) shr 31

proc CMP(x, y: uint32): int32 {.inline.} =
  cast[int32](GT(x, y)) or -(cast[int32](GT(y, x)))

proc EQ0(x: int32): uint32 {.inline.} =
  var q = cast[uint32](x)
  result = not(q or -q) shr 31

proc NEQ(x, y: uint32): uint32 {.inline.} =
  var q = cast[uint32](x xor y)
  result = ((q or -q) shr 31)

proc LT0(x: int32): uint32 {.inline.} =
  result = cast[uint32](x) shr 31

proc checkScalar*(scalar: openArray[byte]): uint32 =
  var z = 0'u32
  var c = 0'i32
  for u in scalar:
    z = z or u
  if len(scalar) == len(CurveOrder):
    for i in countdown(scalar.high, 0):
      c = c or (-(cast[int32](EQ0(c))) and CMP(scalar[i], CurveOrder[i]))
  else:
    c = -1
  result = NEQ(z, 0'u32) and LT0(c)

proc random*(t: typedesc[EdPrivateKey], rng: var BrHmacDrbgContext): EdPrivateKey =
  ## Generate new random ED25519 private key using the given random number generator
  var
    point: GeP3
    pk: array[EdPublicKeySize, byte]
    res: EdPrivateKey

  brHmacDrbgGenerate(addr rng, addr res.data[0], 32)

  var hh = sha512.digest(res.data.toOpenArray(0, 31))
  hh.data[0] = hh.data[0] and 0xF8'u8
  hh.data[31] = hh.data[31] and 0x3F'u8
  hh.data[31] = hh.data[31] or 0x40'u8
  geScalarMultBase(point, hh.data)
  geP3ToBytes(pk, point)
  res.data[32..63] = pk

  res

proc random*(t: typedesc[EdKeyPair], rng: var BrHmacDrbgContext): EdKeyPair =
  ## Generate new random ED25519 private and public keypair using OS specific
  ## CSPRNG.
  var
    point: GeP3
    res: EdKeyPair

  brHmacDrbgGenerate(addr rng, addr res.seckey.data[0], 32)

  var hh = sha512.digest(res.seckey.data.toOpenArray(0, 31))
  hh.data[0] = hh.data[0] and 0xF8'u8
  hh.data[31] = hh.data[31] and 0x3F'u8
  hh.data[31] = hh.data[31] or 0x40'u8
  geScalarMultBase(point, hh.data)
  geP3ToBytes(res.pubkey.data, point)
  res.seckey.data[32..63] = res.pubkey.data

  res

proc getPublicKey*(key: EdPrivateKey): EdPublicKey =
  ## Calculate and return ED25519 public key from private key ``key``.
  copyMem(addr result.data[0], unsafeAddr key.data[32], 32)

proc toBytes*(key: EdPrivateKey, data: var openArray[byte]): int =
  ## Serialize ED25519 `private key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## ED25519 private key.
  result = len(key.data)
  if len(data) >= result:
    copyMem(addr data[0], unsafeAddr key.data[0], len(key.data))

proc toBytes*(key: EdPublicKey, data: var openArray[byte]): int =
  ## Serialize ED25519 `public key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## ED25519 public key.
  result = len(key.data)
  if len(data) >= result:
    copyMem(addr data[0], unsafeAddr key.data[0], len(key.data))

proc toBytes*(sig: EdSignature, data: var openArray[byte]): int =
  ## Serialize ED25519 `signature` ``sig`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## ED25519 signature.
  result = len(sig.data)
  if len(data) >= result:
    copyMem(addr data[0], unsafeAddr sig.data[0], len(sig.data))

proc getBytes*(key: EdPrivateKey): seq[byte] = @(key.data)
  ## Serialize ED25519 `private key` and return it.

proc getBytes*(key: EdPublicKey): seq[byte] = @(key.data)
  ## Serialize ED25519 `public key` and return it.

proc getBytes*(sig: EdSignature): seq[byte] = @(sig.data)
  ## Serialize ED25519 `signature` and return it.

proc `==`*(eda, edb: EdPrivateKey): bool =
  ## Compare ED25519 `private key` objects for equality.
  result = CT.isEqual(eda.data, edb.data)

proc `==`*(eda, edb: EdPublicKey): bool =
  ## Compare ED25519 `public key` objects for equality.
  result = CT.isEqual(eda.data, edb.data)

proc `==`*(eda, edb: EdSignature): bool =
  ## Compare ED25519 `signature` objects for equality.
  result = CT.isEqual(eda.data, edb.data)

proc `$`*(key: EdPrivateKey): string =
  ## Return string representation of ED25519 `private key`.
  ncrutils.toHex(key.data)

proc `$`*(key: EdPublicKey): string =
  ## Return string representation of ED25519 `private key`.
  ncrutils.toHex(key.data)

proc `$`*(sig: EdSignature): string =
  ## Return string representation of ED25519 `signature`.
  ncrutils.toHex(sig.data)

proc init*(key: var EdPrivateKey, data: openArray[byte]): bool =
  ## Initialize ED25519 `private key` ``key`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let length = EdPrivateKeySize
  if len(data) >= length:
    copyMem(addr key.data[0], unsafeAddr data[0], length)
    result = true

proc init*(key: var EdPublicKey, data: openArray[byte]): bool =
  ## Initialize ED25519 `public key` ``key`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let length = EdPublicKeySize
  if len(data) >= length:
    copyMem(addr key.data[0], unsafeAddr data[0], length)
    result = true

proc init*(sig: var EdSignature, data: openArray[byte]): bool =
  ## Initialize ED25519 `signature` ``sig`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let length = EdSignatureSize
  if len(data) >= length:
    copyMem(addr sig.data[0], unsafeAddr data[0], length)
    result = true

proc init*(key: var EdPrivateKey, data: string): bool =
  ## Initialize ED25519 `private key` ``key`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  init(key, ncrutils.fromHex(data))

proc init*(key: var EdPublicKey, data: string): bool =
  ## Initialize ED25519 `public key` ``key`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  init(key, ncrutils.fromHex(data))

proc init*(sig: var EdSignature, data: string): bool =
  ## Initialize ED25519 `signature` ``sig`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  init(sig, ncrutils.fromHex(data))

proc init*(t: typedesc[EdPrivateKey],
           data: openArray[byte]): Result[EdPrivateKey, EdError] =
  ## Initialize ED25519 `private key` from raw binary representation ``data``
  ## and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc init*(t: typedesc[EdPublicKey],
           data: openArray[byte]): Result[EdPublicKey, EdError] =
  ## Initialize ED25519 `public key` from raw binary representation ``data``
  ## and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc init*(t: typedesc[EdSignature],
           data: openArray[byte]): Result[EdSignature, EdError] =
  ## Initialize ED25519 `signature` from raw binary representation ``data``
  ## and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc init*(t: typedesc[EdPrivateKey],
           data: string): Result[EdPrivateKey, EdError] =
  ## Initialize ED25519 `private key` from hexadecimal string representation
  ## ``data`` and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc init*(t: typedesc[EdPublicKey],
           data: string): Result[EdPublicKey, EdError] =
  ## Initialize ED25519 `public key` from hexadecimal string representation
  ## ``data`` and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc init*(t: typedesc[EdSignature],
           data: string): Result[EdSignature, EdError] =
  ## Initialize ED25519 `signature` from hexadecimal string representation
  ## ``data`` and return constructed object.
  var res: t
  if not init(res, data):
    err(EdIncorrectError)
  else:
    ok(res)

proc clear*(key: var EdPrivateKey) =
  ## Wipe and clear memory of ED25519 `private key`.
  burnMem(key.data)

proc clear*(key: var EdPublicKey) =
  ## Wipe and clear memory of ED25519 `public key`.
  burnMem(key.data)

proc clear*(sig: var EdSignature) =
  ## Wipe and clear memory of ED25519 `signature`.
  burnMem(sig.data)

proc clear*(pair: var EdKeyPair) =
  ## Wipe and clear memory of ED25519 `key pair`.
  burnMem(pair.seckey.data)
  burnMem(pair.pubkey.data)

proc sign*[T: byte|char](key: EdPrivateKey,
                         message: openArray[T]): EdSignature {.gcsafe, noinit.} =
  ## Create ED25519 signature of data ``message`` using private key ``key``.
  var ctx: sha512
  var r: GeP3

  ctx.init()
  ctx.update(key.data.toOpenArray(0, 31))
  var hash = ctx.finish()

  hash.data[0] = hash.data[0] and 0xF8'u8
  hash.data[31] = hash.data[31] and 0x3F'u8
  hash.data[31] = hash.data[31] or 0x40'u8

  ctx.init()
  ctx.update(hash.data.toOpenArray(32, 63))
  ctx.update(message)
  var nonce = ctx.finish()

  scReduce(nonce.data)
  geScalarMultBase(r, nonce.data)
  geP3ToBytes(result.data.toOpenArray(0, 31), r)

  ctx.init()
  ctx.update(result.data.toOpenArray(0, 31))
  ctx.update(key.data.toOpenArray(32, 63))
  ctx.update(message)
  var hram = ctx.finish()
  ctx.clear()

  scReduce(hram.data)
  scMulAdd(result.data.toOpenArray(32, 63), hram.data.toOpenArray(0, 31),
           hash.data.toOpenArray(0, 31), nonce.data.toOpenArray(0, 31))

proc verify*[T: byte|char](sig: EdSignature, message: openArray[T],
                           key: EdPublicKey): bool =
  ## Verify ED25519 signature ``sig`` using public key ``key`` and data
  ## ``message``.
  ##
  ## Return ``true`` if message verification succeeded, ``false`` if
  ## verification failed.
  var ctx: sha512
  var rcheck: array[32, byte]
  var a: GeP3
  var r: GeP2
  if (sig.data[63] and 0xE0'u8) != 0:
    return false

  if checkScalar(sig.data.toOpenArray(32, 63)) == 0:
    return false
  if geFromBytesNegateVartime(a, key.data.toOpenArray(0, 31)) != 0:
    return false

  ctx.init()
  ctx.update(sig.data.toOpenArray(0, 31))
  ctx.update(key.data.toOpenArray(0, 31))
  ctx.update(message)
  var hash = ctx.finish()
  scReduce(hash.data)

  geDoubleScalarMultVartime(r, hash.data.toOpenArray(0, 31),
                            a, sig.data.toOpenArray(32, 63))
  geToBytes(rcheck, r)

  result = (verify32(sig.data.toOpenArray(0, 31), rcheck) == 0)
