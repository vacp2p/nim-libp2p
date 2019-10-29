import unittest
import ../libp2p/base64

when defined(nimHasUsed): {.used.}

const TVBasePadding = [
  ["f", "Zg=="],
  ["fo", "Zm8="],
  ["foo", "Zm9v"],
  ["foob", "Zm9vYg=="],
  ["fooba", "Zm9vYmE="],
  ["foobar", "Zm9vYmFy"]
]

const TVBaseNoPadding = [
  ["f", "Zg"],
  ["fo", "Zm8"],
  ["foo", "Zm9v"],
  ["foob", "Zm9vYg"],
  ["fooba", "Zm9vYmE"],
  ["foobar", "Zm9vYmFy"]
]

suite "BASE64 encoding test suite":
  test "Empty seq/string test":
    var empty1 = newSeq[byte]()
    var empty2 = ""
    var encoded = newString(16)
    var decoded = newSeq[byte](16)

    var o1, o2, o3, o4: int
    var e1 = Base64.encode(empty1)
    var e2 = Base64Url.encode(empty1)
    var e3 = Base64Pad.encode(empty1)
    var e4 = Base64UrlPad.encode(empty1)
    check:
      Base64.encode(empty1, encoded, o1) == Base64Status.Success
      Base64Url.encode(empty1, encoded, o2) == Base64Status.Success
      Base64Pad.encode(empty1, encoded, o3) == Base64Status.Success
      Base64UrlPad.encode(empty1, encoded, o4) == Base64Status.Success
      len(e1) == 0
      len(e2) == 0
      len(e3) == 0
      len(e4) == 0
      o1 == 0
      o2 == 0
      o3 == 0
      o4 == 0
    var d1 = Base64.decode("")
    var d2 = Base64Url.decode("")
    var d3 = Base64Pad.decode("")
    var d4 = Base64UrlPad.decode("")
    check:
      Base64.decode(empty2, decoded, o1) == Base64Status.Success
      Base64Url.decode(empty2, decoded, o2) == Base64Status.Success
      Base64Pad.decode(empty2, decoded, o3) == Base64Status.Success
      Base64UrlPad.decode(empty2, decoded, o4) == Base64Status.Success
      len(d1) == 0
      len(d2) == 0
      len(d3) == 0
      len(d4) == 0
      o1 == 0
      o2 == 0
      o3 == 0
      o4 == 0

  test "Zero test":
    var s = newString(256)
    for i in 0..255:
      s[i] = 'A'
    var buffer: array[256, byte]
    for i in 0..255:
      var a = Base64.encode(buffer.toOpenArray(0, i))
      var b = Base64.decode(a)
      check b == buffer[0..i]

  test "Leading zero test":
    var buffer: array[256, byte]
    for i in 0..255:
      buffer[255] = byte(i)
      var a = Base64.encode(buffer)
      var b = Base64.decode(a)
      check:
        equalMem(addr buffer[0], addr b[0], 256) == true

  test "BASE64 padding test vectors":
    for item in TVBasePadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base64Pad.encode(plain)
      var e2 = newString(Base64Pad.encodedLength(len(plain)))
      check:
        Base64Pad.encode(plain, e2, elen) == Base64Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base64Pad.decode(expect)
      var d2 = newSeq[byte](Base64Pad.decodedLength(len(expect)))
      check:
        Base64Pad.decode(expect, d2, dlen) == Base64Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "BASE64 no padding test vectors":
    for item in TVBaseNoPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base64.encode(plain)
      var e2 = newString(Base64.encodedLength(len(plain)))
      check:
        Base64.encode(plain, e2, elen) == Base64Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base64.decode(expect)
      var d2 = newSeq[byte](Base64.decodedLength(len(expect)))
      check:
        Base64.decode(expect, d2, dlen) == Base64Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "Buffer Overrun test":
    var encres = ""
    var encsize = 0
    var decres: seq[byte] = @[]
    var decsize = 0
    check:
      Base64.encode([0'u8], encres, encsize) == Base64Status.Overrun
      encsize == Base64.encodedLength(1)
      Base64.decode("AA", decres, decsize) == Base64Status.Overrun
      decsize == Base64.decodedLength(2)

  test "Incorrect test":
    var decres = newSeq[byte](10)
    var decsize = 0
    check:
      Base64.decode("A", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64.decode("AAAAA", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64.decode("!", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64.decode("!!", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64.decode("AA==", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64.decode("_-", decres, decsize) == Base64Status.Incorrect
      decsize == 0
      Base64Url.decode("/+", decres, decsize) == Base64Status.Incorrect
      decsize == 0
