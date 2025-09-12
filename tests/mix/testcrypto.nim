{.used.}

import chronicles, nimcrypto, results, unittest
import ../../libp2p/protocols/mix/crypto

suite "cryptographic_functions_tests":
  test "aes_ctr_encrypt_decrypt":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisdata")

    let encryptedResult = aes_ctr(key, iv, data)
    if encryptedResult.isErr:
      error "Encryption failed", err = encryptedResult.error
      fail()
    let encrypted = encryptedResult.get()

    let decryptedResult = aes_ctr(key, iv, encrypted)
    if decryptedResult.isErr:
      error "Decryption failed", err = decryptedResult.error
      fail()
    let decrypted = decryptedResult.get()

    if data != decrypted:
      error "Decrypted data does not match the original data",
        original = data, decrypted = decrypted
      fail()

    if data == encrypted:
      error "Encrypted data should not match the original data",
        original = data, encrypted = encrypted
      fail()

  test "sha256_hash_computation":
    let
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      expectedHashHex =
        "b53a20ecf0814267a83be82f941778ffda4b85fbf93a07847539f645ff5f1b9b"
      expectedHash = fromHex(expectedHashHex)
      hash = sha256_hash(data)

    if hash != expectedHash:
      error "SHA-256 hash does not match the expected hash",
        hashed = hash, expected = expectedHash
      fail()

  test "kdf_computation":
    let
      key: seq[byte] = cast[seq[byte]]("thisiskey")
      expectedKdfHex = "37c9842d37dc404854428a0a3554dcaa"
      expectedKdf = fromHex(expectedKdfHex)
      derivedKey = kdf(key)

    if derivedKey != expectedKdf:
      error "Derived key does not match the expected key",
        key = derivedKey, expected = expectedKdf
      fail()

  test "hmac_computation":
    let
      key: seq[byte] = cast[seq[byte]]("thisiskey")
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      expectedHmacHex = "b075dd302655e085d35e8cef5dfdf101"
      expectedHmac = fromHex(expectedHmacHex)
      hmacResult = hmac(key, data)

    if hmacResult != expectedHmac:
      error "HMAC does not match the expected HMAC",
        hmac = hmacResult, expected = expectedHmac
      fail()

  test "aes_ctr_empty_data":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      emptyData: array[0, byte] = []

    let encryptedResult = aes_ctr(key, iv, emptyData)
    if encryptedResult.isErr:
      error "Encryption failed", err = encryptedResult.error
      fail()
    let encrypted = encryptedResult.get()

    let decryptedResult = aes_ctr(key, iv, encrypted)
    if decryptedResult.isErr:
      error "Decryption failed", err = decryptedResult.error
      fail()
    let decrypted = decryptedResult.get()

    if emptyData != decrypted:
      error "Decrypted empty data does not match the original empty data",
        original = emptyData, decrypted = decrypted
      fail()

    if emptyData != encrypted:
      error "Encrypted empty data should still be empty",
        original = emptyData, encrypted = encrypted
      fail()

  test "sha256_hash_empty_data":
    let
      emptyData: array[0, byte] = []
      expectedHashHex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      expectedHash = fromHex(expectedHashHex)
      hash = sha256_hash(emptyData)

    if hash != expectedHash:
      error "SHA-256 hash of empty data does not match the expected hash",
        hashed = hash, expected = expectedHash
      fail()

  test "kdf_empty_key":
    let
      emptyKey: array[0, byte] = []
      expectedKdfHex = "e3b0c44298fc1c149afbf4c8996fb924"
      expectedKdf = fromHex(expectedKdfHex)
      derivedKey = kdf(emptyKey)

    if derivedKey != expectedKdf:
      error "Derived key from empty key does not match the expected key",
        key = derivedKey, expected = expectedKdf
      fail()

  test "hmac_empty_key_and_data":
    let
      emptyKey: array[0, byte] = []
      emptyData: array[0, byte] = []
      expectedHmacHex = "b613679a0814d9ec772f95d778c35fc5"
      expectedHmac = fromHex(expectedHmacHex)
      hmacResult = hmac(emptyKey, emptyData)

    if hmacResult != expectedHmac:
      error "HMAC of empty key and data does not match the expected HMAC",
        hmac = hmacResult, expected = expectedHmac
      fail()

  test "aes_ctr_start_index_zero_index":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisdata")
      startIndex = 0

    let encryptedResult = aes_ctr_start_index(key, iv, data, startIndex)
    if encryptedResult.isErr:
      error "Encryption with start index failed", err = encryptedResult.error
      fail()
    let encrypted = encryptedResult.get()

    let expectedResult = aes_ctr(key, iv, data)
    if expectedResult.isErr:
      error "Encryption failed", err = expectedResult.error
      fail()
    let expected = expectedResult.get()

    if encrypted != expected:
      error "Encrypted data with start index 0 should match the full AES-CTR encryption",
        encrypted = encrypted, expected = expected
      fail()

  test "aes_ctr_start_index_empty_data":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      emptyData: array[0, byte] = []
      startIndex = 0

    let encryptedResult = aes_ctr_start_index(key, iv, emptyData, startIndex)
    if encryptedResult.isErr:
      error "Encryption with start index failed", err = encryptedResult.error
      fail()
    let encrypted = encryptedResult.get()

    if emptyData != encrypted:
      error "Encrypted empty data with start index 0 should be empty",
        original = emptyData, encrypted = encrypted
      fail()

  test "aes_ctr_start_index_middle":
    let
      key = cast[array[16, byte]]("thisis16byteskey")
      iv = cast[array[16, byte]]("thisis16bytesiv!")
      data: seq[byte] = cast[seq[byte]]("thisisverylongdata")
      startIndex = 16

    let encrypted2Result =
      aes_ctr_start_index(key, iv, data[startIndex ..^ 1], startIndex)
    if encrypted2Result.isErr:
      error "Encryption with start index failed", err = encrypted2Result.error
      fail()
    let encrypted2 = encrypted2Result.get()

    let encrypted1Result = aes_ctr(key, iv, data[0 .. startIndex - 1])
    if encrypted1Result.isErr:
      error "Encryption with start index failed", err = encrypted1Result.error
      fail()
    let encrypted1 = encrypted1Result.get()

    let expectedResult = aes_ctr(key, iv, data)
    if expectedResult.isErr:
      error "Encryption failed", err = expectedResult.error
      fail()
    let expected = expectedResult.get()

    if encrypted1 & encrypted2 != expected:
      error "Encrypted data with start index should match the full AES-CTR encryption",
        encrypted = encrypted1 & encrypted2, expected = expected
      fail()
