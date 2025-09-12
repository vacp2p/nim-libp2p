import endians, nimcrypto, results

# This function processes 'data' using AES in CTR mode.
# For CTR mode, the same function handles both encryption and decryption.
proc aes_ctr*(key, iv, data: openArray[byte]): Result[seq[byte], string] =
  if key.len != 16:
    return err("Key must be 16 bytes for AES-128")
  if iv.len != 16:
    return err("IV must be 16 bytes for AES-128")

  var
    ctx: CTR[aes128]
    output = newSeq[byte](data.len)

  ctx.init(key, iv)
  ctx.encrypt(data, output)
  ctx.clear()

  return ok(output)

# This function advances the counter in the AES-CTR IV by a specified number of blocks.
proc advance_ctr*(iv: var openArray[byte], blocks: int) =
  var counter: uint64
  bigEndian64(addr counter, addr iv[8])
  counter += uint64(blocks)
  bigEndian64(addr iv[8], addr counter)

# This function encrypting processes 'data' using AES in CTR mode from startIndex, without processing all preceding data.
# For CTR mode, the same function handles both encryption and decryption.
proc aes_ctr_start_index*(
    key, iv, data: openArray[byte], startIndex: int
): Result[seq[byte], string] =
  if key.len != 16:
    return err("Key must be 16 bytes for AES-128")
  if iv.len != 16:
    return err("IV must be 16 bytes for AES-128")
  if startIndex mod 16 != 0:
    return err("Start index must be a multiple of 16")

  var advIV = @iv

  # Advance the counter to the start index
  let blocksToAdvance = startIndex div 16
  advance_ctr(advIV, blocksToAdvance)

  return aes_ctr(key, advIV, data)

# This function hashes 'data' using SHA-256.
proc sha256_hash*(data: openArray[byte]): array[32, byte] =
  return sha256.digest(data).data

# This function returns the hash of 'key' truncated to 16 bytes.
proc kdf*(key: openArray[byte]): seq[byte] =
  let hash = sha256_hash(key)
  return hash[0 .. 15]

# This function computes a HMAC for 'data' using given 'key'.
proc hmac*(key, data: openArray[byte]): seq[byte] =
  let hmac = sha256.hmac(key, data).data
  return hmac[0 .. 15]
