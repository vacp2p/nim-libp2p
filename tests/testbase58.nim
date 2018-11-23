import unittest
import ../libp2p/base58

proc hexToBytes*(a: string, result: var openarray[byte]) =
  doAssert(len(a) == 2 * len(result))
  var i = 0
  var k = 0
  var r = 0
  if len(a) > 0:
    while i < len(a):
      let c = a[i]
      if i != 0 and i %% 2 == 0:
        result[k] = r.byte
        r = 0
        inc(k)
      else:
        r = r shl 4
      case c
      of 'a'..'f':
        r = r or (10 + ord(c) - ord('a'))
      of 'A'..'F':
        r = r or (10 + ord(c) - ord('A'))
      of '0'..'9':
        r = r or (ord(c) - ord('0'))
      else:
        doAssert(false)
      inc(i)
    result[k] = r.byte

proc fromHex*(a: string): seq[byte] =
  doAssert(len(a) %% 2 == 0)
  if len(a) == 0:
    result = newSeq[byte]()
  else:
    result = newSeq[byte](len(a) div 2)
    hexToBytes(a, result)

const TestVectors = [
  ["", ""],
  ["61", "2g"],
  ["626262", "a3gV"],
  ["636363", "aPEr"],
  ["73696d706c792061206c6f6e6720737472696e67", "2cFupjhnEsSn59qHXstmK2ffpLv2"],
  ["00eb15231dfceb60925886b67d065299925915aeb172c06647", "1NS17iag9jJgTHD1VXjvLCEnZuQ3rJDE9L"],
  ["516b6fcd0f", "ABnLTmg"],
  ["bf4f89001e670274dd", "3SEo3LWLoPntC"],
  ["572e4794", "3EFU7m"],
  ["ecac89cad93923c02321", "EJDM8drfXA6uyA"],
  ["10c8511e", "Rt5zm"],
  ["00000000000000000000", "1111111111"],
  ["000111d38e5fc9071ffcd20b4a763cc9ae4f252bb4e48fd66a835e252ada93ff480d6dd43dc62a641155a5", "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"],
  ["000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", "1cWB5HCBdLjAuqGGReWE3R3CguuwSjw6RHn39s2yuDRTS5NsBgNiFpWgAnEx6VQi8csexkgYw3mdYrMHr8x9i7aEwP8kZ7vccXWqKDvGv3u1GxFKPuAkn8JCPPGDMf3vMMnbzm6Nh9zh1gcNsMvH3ZNLmP5fSG6DGbbi2tuwMWPthr4boWwCxf7ewSgNQeacyozhKDDQQ1qL5fQFUW52QKUZDZ5fw3KXNQJMcNTcaB723LchjeKun7MuGW5qyCBZYzA1KjofN1gYBV3NqyhQJ3Ns746GNuf9N2pQPmHz4xpnSrrfCvy6TVVz5d4PdrjeshsWQwpZsZGzvbdAdN8MKV5QsBDY"]
]

suite "BASE58 encoding test suite":
  test "Empty seq/string test":
    var a = Base58.encode([])
    check len(a) == 0
    var b = Base58.decode("")
    check len(b) == 0
  test "Zero test":
    var s = newString(256)
    for i in 0..255:
      s[i] = '1'
    var buffer: array[256, byte]
    for i in 0..255:
      var a = Base58.encode(buffer.toOpenArray(0, i))
      check a == s[0..i]
      var b = Base58.decode(a)
      check b == buffer[0..i]
  test "Leading zero test":
    var buffer: array[256, byte]
    for i in 0..255:
      buffer[255] = byte(i)
      var a = Base58.encode(buffer)
      var b = Base58.decode(a)
      check:
        equalMem(addr buffer[0], addr b[0], 256) == true
  test "Small amount of bytes test":
    var buffer1: array[1, byte]
    var buffer2: array[2, byte]
    for i in 0..255:
      buffer1[0] = byte(i)
      var enc = Base58.encode(buffer1)
      var dec = Base58.decode(enc)
      check:
        len(dec) == 1
        dec[0] == buffer1[0]

    for i in 0..255:
      for k in 0..255:
        buffer2[0] = byte(i)
        buffer2[1] = byte(k)
        var enc = Base58.encode(buffer2)
        var dec = Base58.decode(enc)
        check:
          len(dec) == 2
          dec[0] == buffer2[0]
          dec[1] == buffer2[1]
  test "Test Vectors test":
    for item in TestVectors:
      var a = fromHex(item[0])
      var enc = Base58.encode(a)
      var dec = Base58.decode(item[1])
      check:
        enc == item[1]
        dec == a
  test "Buffer Overrun test":
    var encres = ""
    var encsize = 0
    var decres: seq[byte] = @[]
    var decsize = 0
    check:
      Base58.encode([0'u8], encres, encsize) == Base58Status.Overrun
      encsize == 1
      Base58.decode("1", decres, decsize) == Base58Status.Overrun
      decsize == 5
  test "Incorrect test":
    var decres = newSeq[byte](10)
    var decsize = 0
    check:
      Base58.decode("l", decres, decsize) == Base58Status.Incorrect
      decsize == 0
      Base58.decode("2l", decres, decsize) == Base58Status.Incorrect
      decsize == 0
      Base58.decode("O", decres, decsize) == Base58Status.Incorrect
      decsize == 0
      Base58.decode("2O", decres, decsize) == Base58Status.Incorrect
      decsize == 0

