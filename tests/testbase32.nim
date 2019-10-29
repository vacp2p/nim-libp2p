import unittest
import ../libp2p/base32

when defined(nimHasUsed): {.used.}

const TVBaseUpperPadding = [
  ["f", "MY======"],
  ["fo", "MZXQ===="],
  ["foo", "MZXW6==="],
  ["foob", "MZXW6YQ="],
  ["fooba", "MZXW6YTB"],
  ["foobar", "MZXW6YTBOI======"]
]

const TVBaseUpperNoPadding = [
  ["f", "MY"],
  ["fo", "MZXQ"],
  ["foo", "MZXW6"],
  ["foob", "MZXW6YQ"],
  ["fooba", "MZXW6YTB"],
  ["foobar", "MZXW6YTBOI"]
]

const TVBaseLowerPadding = [
  ["f", "my======"],
  ["fo", "mzxq===="],
  ["foo", "mzxw6==="],
  ["foob", "mzxw6yq="],
  ["fooba", "mzxw6ytb"],
  ["foobar", "mzxw6ytboi======"]
]

const TVBaseLowerNoPadding = [
  ["f", "my"],
  ["fo", "mzxq"],
  ["foo", "mzxw6"],
  ["foob", "mzxw6yq"],
  ["fooba", "mzxw6ytb"],
  ["foobar", "mzxw6ytboi"]
]

const TVHexUpperPadding = [
  ["f", "CO======"],
  ["fo", "CPNG===="],
  ["foo", "CPNMU==="],
  ["foob", "CPNMUOG="],
  ["fooba", "CPNMUOJ1"],
  ["foobar", "CPNMUOJ1E8======"]
]

const TVHexUpperNoPadding = [
  ["f", "CO"],
  ["fo", "CPNG"],
  ["foo", "CPNMU"],
  ["foob", "CPNMUOG"],
  ["fooba", "CPNMUOJ1"],
  ["foobar", "CPNMUOJ1E8"]
]

const TVHexLowerPadding = [
  ["f", "co======"],
  ["fo", "cpng===="],
  ["foo", "cpnmu==="],
  ["foob", "cpnmuog="],
  ["fooba", "cpnmuoj1"],
  ["foobar", "cpnmuoj1e8======"]
]

const TVHexLowerNoPadding = [
  ["f", "co"],
  ["fo", "cpng"],
  ["foo", "cpnmu"],
  ["foob", "cpnmuog"],
  ["fooba", "cpnmuoj1"],
  ["foobar", "cpnmuoj1e8"]
]

suite "BASE32 encoding test suite":
  test "Empty seq/string test":
    var empty1 = newSeq[byte]()
    var empty2 = ""
    var encoded = newString(16)
    var decoded = newSeq[byte](16)

    var o1, o2, o3, o4, o5, o6, o7, o8: int
    var e1 = Base32Upper.encode(empty1)
    var e2 = Base32Lower.encode(empty1)
    var e3 = Base32UpperPad.encode(empty1)
    var e4 = Base32LowerPad.encode(empty1)
    var e5 = HexBase32Upper.encode(empty1)
    var e6 = HexBase32Lower.encode(empty1)
    var e7 = HexBase32UpperPad.encode(empty1)
    var e8 = HexBase32LowerPad.encode(empty1)
    check:
      Base32Upper.encode(empty1, encoded, o1) == Base32Status.Success
      Base32Lower.encode(empty1, encoded, o2) == Base32Status.Success
      Base32UpperPad.encode(empty1, encoded, o3) == Base32Status.Success
      Base32LowerPad.encode(empty1, encoded, o4) == Base32Status.Success
      HexBase32Upper.encode(empty1, encoded, o5) == Base32Status.Success
      HexBase32Lower.encode(empty1, encoded, o6) == Base32Status.Success
      HexBase32UpperPad.encode(empty1, encoded, o7) == Base32Status.Success
      HexBase32LowerPad.encode(empty1, encoded, o8) == Base32Status.Success
      len(e1) == 0
      len(e2) == 0
      len(e3) == 0
      len(e4) == 0
      len(e5) == 0
      len(e6) == 0
      len(e7) == 0
      len(e8) == 0
      o1 == 0
      o2 == 0
      o3 == 0
      o4 == 0
      o5 == 0
      o6 == 0
      o7 == 0
      o8 == 0
    var d1 = Base32Upper.decode("")
    var d2 = Base32Lower.decode("")
    var d3 = Base32UpperPad.decode("")
    var d4 = Base32LowerPad.decode("")
    var d5 = HexBase32Upper.decode("")
    var d6 = HexBase32Lower.decode("")
    var d7 = HexBase32UpperPad.decode("")
    var d8 = HexBase32LowerPad.decode("")
    check:
      Base32Upper.decode(empty2, decoded, o1) == Base32Status.Success
      Base32Lower.decode(empty2, decoded, o2) == Base32Status.Success
      Base32UpperPad.decode(empty2, decoded, o3) == Base32Status.Success
      Base32LowerPad.decode(empty2, decoded, o4) == Base32Status.Success
      HexBase32Upper.decode(empty2, decoded, o5) == Base32Status.Success
      HexBase32Lower.decode(empty2, decoded, o6) == Base32Status.Success
      HexBase32UpperPad.decode(empty2, decoded, o7) == Base32Status.Success
      HexBase32LowerPad.decode(empty2, decoded, o8) == Base32Status.Success
      len(d1) == 0
      len(d2) == 0
      len(d3) == 0
      len(d4) == 0
      len(d5) == 0
      len(d6) == 0
      len(d7) == 0
      len(d8) == 0
      o1 == 0
      o2 == 0
      o3 == 0
      o4 == 0
      o5 == 0
      o6 == 0
      o7 == 0
      o8 == 0

  test "Zero test":
    var s = newString(256)
    for i in 0..255:
      s[i] = 'A'
    var buffer: array[256, byte]
    for i in 0..255:
      var a = Base32.encode(buffer.toOpenArray(0, i))
      var b = Base32.decode(a)
      check b == buffer[0..i]

  test "Leading zero test":
    var buffer: array[256, byte]
    for i in 0..255:
      buffer[255] = byte(i)
      var a = Base32.encode(buffer)
      var b = Base32.decode(a)
      check:
        equalMem(addr buffer[0], addr b[0], 256) == true

  test "BASE32 uppercase padding test vectors":
    for item in TVBaseUpperPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base32UpperPad.encode(plain)
      var e2 = newString(Base32UpperPad.encodedLength(len(plain)))
      check:
        Base32UpperPad.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base32UpperPad.decode(expect)
      var d2 = newSeq[byte](Base32UpperPad.decodedLength(len(expect)))
      check:
        Base32UpperPad.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "BASE32 lowercase padding test vectors":
    for item in TVBaseLowerPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base32LowerPad.encode(plain)
      var e2 = newString(Base32LowerPad.encodedLength(len(plain)))
      check:
        Base32LowerPad.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base32LowerPad.decode(expect)
      var d2 = newSeq[byte](Base32LowerPad.decodedLength(len(expect)))
      check:
        Base32LowerPad.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "BASE32 uppercase no-padding test vectors":
    for item in TVBaseUpperNoPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base32Upper.encode(plain)
      var e2 = newString(Base32Upper.encodedLength(len(plain)))
      check:
        Base32Upper.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base32Upper.decode(expect)
      var d2 = newSeq[byte](Base32Upper.decodedLength(len(expect)))
      check:
        Base32Upper.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "BASE32 lowercase no-padding test vectors":
    for item in TVBaseLowerNoPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = Base32Lower.encode(plain)
      var e2 = newString(Base32Lower.encodedLength(len(plain)))
      check:
        Base32Lower.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = Base32Lower.decode(expect)
      var d2 = newSeq[byte](Base32Lower.decodedLength(len(expect)))
      check:
        Base32Lower.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "HEX-BASE32 uppercase padding test vectors":
    for item in TVHexUpperPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = HexBase32UpperPad.encode(plain)
      var e2 = newString(HexBase32UpperPad.encodedLength(len(plain)))
      check:
        HexBase32UpperPad.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = HexBase32UpperPad.decode(expect)
      var d2 = newSeq[byte](HexBase32UpperPad.decodedLength(len(expect)))
      check:
        HexBase32UpperPad.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "HEX-BASE32 lowercase padding test vectors":
    for item in TVHexLowerPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = HexBase32LowerPad.encode(plain)
      var e2 = newString(HexBase32LowerPad.encodedLength(len(plain)))
      check:
        HexBase32LowerPad.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = HexBase32LowerPad.decode(expect)
      var d2 = newSeq[byte](HexBase32LowerPad.decodedLength(len(expect)))
      check:
        HexBase32LowerPad.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "HEX-BASE32 uppercase no-padding test vectors":
    for item in TVHexUpperNoPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = HexBase32Upper.encode(plain)
      var e2 = newString(HexBase32Upper.encodedLength(len(plain)))
      check:
        HexBase32Upper.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = HexBase32Upper.decode(expect)
      var d2 = newSeq[byte](HexBase32Upper.decodedLength(len(expect)))
      check:
        HexBase32Upper.decode(expect, d2, dlen) == Base32Status.Success
      d2.setLen(dlen)
      check:
        d1 == plain
        d2 == plain

  test "HEX-BASE32 lowercase no-padding test vectors":
    for item in TVHexLowerNoPadding:
      let plain = cast[seq[byte]](item[0])
      let expect = item[1]
      var elen = 0
      var dlen = 0

      var e1 = HexBase32Lower.encode(plain)
      var e2 = newString(HexBase32Lower.encodedLength(len(plain)))
      check:
        HexBase32Lower.encode(plain, e2, elen) == Base32Status.Success
      e2.setLen(elen)
      check:
        e1 == expect
        e2 == expect

      var d1 = HexBase32Lower.decode(expect)
      var d2 = newSeq[byte](HexBase32Lower.decodedLength(len(expect)))
      check:
        HexBase32Lower.decode(expect, d2, dlen) == Base32Status.Success
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
      Base32.encode([0'u8], encres, encsize) == Base32Status.Overrun
      encsize == Base32.encodedLength(1)
      Base32.decode("AA", decres, decsize) == Base32Status.Overrun
      decsize == Base32.decodedLength(2)

  test "Incorrect test":
    var decres = newSeq[byte](10)
    var decsize = 0
    check:
      Base32.decode("A", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32.decode("AAA", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32.decode("AAAAAA", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32Upper.decode("aa", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32Upper.decode("11", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32Lower.decode("AA", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      Base32Lower.decode("11", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      HexBase32Upper.decode("aa", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      HexBase32Upper.decode("WW", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      HexBase32Lower.decode("AA", decres, decsize) == Base32Status.Incorrect
      decsize == 0
      HexBase32Lower.decode("ww", decres, decsize) == Base32Status.Incorrect
      decsize == 0

