import endians, nimcrypto

proc aes_ctr*(key, iv, data: openArray[byte]): seq[byte] =
  ## Processes 'data' using AES in CTR mode.
  ## For CTR mode, the same function handles both encryption and decryption.
  doAssert key.len == 16, "Key must be 16 bytes for AES-128"
  doAssert iv.len == 16, "IV must be 16 bytes for AES-128"

  var
    ctx: CTR[aes128]
    output = newSeq[byte](data.len)

  ctx.init(key, iv)
  ctx.encrypt(data, output)
  ctx.clear()

  output

proc advance_ctr*(iv: var openArray[byte], blocks: uint64) =
  ## Advances the counter in the AES-CTR IV by a specified number of blocks.
  var counter: uint64
  bigEndian64(addr counter, addr iv[8])
  counter += blocks
  bigEndian64(addr iv[8], addr counter)

proc aes_ctr_start_index*(key, iv, data: openArray[byte], startIndex: int): seq[byte] =
  ## Encrypts 'data' using AES in CTR mode from startIndex, without processing all preceding data.
  ## For CTR mode, the same function handles both encryption and decryption.
  doAssert key.len == 16, "Key must be 16 bytes for AES-128"
  doAssert iv.len == 16, "IV must be 16 bytes for AES-128"
  doAssert startIndex mod 16 == 0, "Start index must be a multiple of 16"

  var advIV = @iv

  # Advance the counter to the start index
  let blocksToAdvance = startIndex div 16
  advance_ctr(advIV, blocksToAdvance.uint64)

  return aes_ctr(key, advIV, data)

proc sha256_hash*(data: openArray[byte]): array[32, byte] =
  ## hashes 'data' using SHA-256.
  return sha256.digest(data).data

proc kdf*(key: openArray[byte]): seq[byte] =
  ## Returns the hash of 'key' truncated to 16 bytes.
  let hash = sha256_hash(key)
  return hash[0 .. 15]

proc hmac*(key, data: openArray[byte]): seq[byte] =
  ## Computes a HMAC for 'data' using given 'key'.
  let hmac = sha256.hmac(key, data).data
  return hmac[0 .. 15]
