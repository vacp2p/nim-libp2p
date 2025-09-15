{.used.}

import nimcrypto, results, unittest
import ../../libp2p/protocols/mix/crypto

suite "cryptographic_functions_tests":
  test "aes_ctr_encrypt_decrypt":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisdata")

    let encrypted = aes_ctr(key, iv, data)
    let decrypted = aes_ctr(key, iv, encrypted)

    check:
      data == decrypted
      data != encrypted

  test "sha256_hash_computation":
    let
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      expectedHashHex =
        "b53a20ecf0814267a83be82f941778ffda4b85fbf93a07847539f645ff5f1b9b"
      expectedHash = fromHex(expectedHashHex)
      hash = sha256_hash(data)

    check hash == expectedHash

  test "kdf_computation":
    let
      key: seq[byte] = cast[seq[byte]]("thisiskey")
      expectedKdfHex = "37c9842d37dc404854428a0a3554dcaa"
      expectedKdf = fromHex(expectedKdfHex)
      derivedKey = kdf(key)

    check derivedKey == expectedKdf

  test "hmac_computation":
    let
      key: seq[byte] = cast[seq[byte]]("thisiskey")
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      expectedHmacHex = "b075dd302655e085d35e8cef5dfdf101"
      expectedHmac = fromHex(expectedHmacHex)
      hmacResult = hmac(key, data)

    check hmacResult == expectedHmac

  test "aes_ctr_empty_data":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      emptyData: array[0, byte] = []

    let encrypted = aes_ctr(key, iv, emptyData)
    let decrypted = aes_ctr(key, iv, encrypted)

    check:
      emptyData == decrypted
      emptyData == encrypted

  test "sha256_hash_empty_data":
    let
      emptyData: array[0, byte] = []
      expectedHashHex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      expectedHash = fromHex(expectedHashHex)
      hash = sha256_hash(emptyData)

    check hash == expectedHash

  test "kdf_empty_key":
    let
      emptyKey: array[0, byte] = []
      expectedKdfHex = "e3b0c44298fc1c149afbf4c8996fb924"
      expectedKdf = fromHex(expectedKdfHex)
      derivedKey = kdf(emptyKey)

    check derivedKey == expectedKdf

  test "hmac_empty_key_and_data":
    let
      emptyKey: array[0, byte] = []
      emptyData: array[0, byte] = []
      expectedHmacHex = "b613679a0814d9ec772f95d778c35fc5"
      expectedHmac = fromHex(expectedHmacHex)
      hmacResult = hmac(emptyKey, emptyData)

    check hmacResult == expectedHmac

  test "aes_ctr_start_index_zero_index":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      startIndex = 0

    let encrypted = aes_ctr_start_index(key, iv, data, startIndex)
    let expected = aes_ctr(key, iv, data)

    check encrypted == expected

  test "aes_ctr_start_index_empty_data":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      emptyData: array[0, byte] = []
      startIndex = 0

    let encrypted = aes_ctr_start_index(key, iv, emptyData, startIndex)

    check emptyData == encrypted

  test "aes_ctr_start_index_middle":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisverylongdata")
      startIndex = 16

    let encrypted2 = aes_ctr_start_index(key, iv, data[startIndex ..^ 1], startIndex)
    let encrypted1 = aes_ctr(key, iv, data[0 .. startIndex - 1])
    let expected = aes_ctr(key, iv, data)

    check encrypted1 & encrypted2 == expected
