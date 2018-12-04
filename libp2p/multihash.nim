## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements MultiHash.
## Supported hashes are:
## 1. IDENTITY
## 2. SHA2-256/SHA2-512
## 3. DBL-SHA2-256
## 4. SHA3/KECCAK
## 5. SHAKE-128/SHAKE-256
## 6. BLAKE2s/BLAKE2s
##
## Hashes which are not yet supported
## 1. SHA1
## 2. SKEIN
## 3. MURMUR
import tables
import nimcrypto/[sha2, keccak, blake2, hash, utils]
import varint, vbuffer, base58

const
  MaxHashSize* = 128

type
  MHashCoderProc* = proc(data: openarray[byte],
                         output: var openarray[byte]) {.nimcall, gcsafe.}
  MHash* = object
    name*: string
    code*: int
    size*: int
    coder*: MHashCoderProc

  MultiHash* = object
    data*: VBuffer
    code*: int
    size*: int
    dpos*: int

  MultiHashError* = object of Exception

proc identhash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var length = if len(data) > len(output): len(output)
                 else: len(data)
    copyMem(addr output[0], unsafeAddr data[0], length)

proc dblsha2_256hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest1 = sha256.digest(data)
    var digest2 = sha256.digest(digest1.data)
    var length = if sha256.sizeDigest > len(output): len(output)
                 else: sha256.sizeDigest
    copyMem(addr output[0], addr digest2.data[0], length)

proc blake2Bhash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = blake2_512.digest(data)
    var length = if blake2_512.sizeDigest > len(output): len(output)
                 else: blake2_512.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc blake2Shash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = blake2_256.digest(data)
    var length = if blake2_256.sizeDigest > len(output): len(output)
                 else: blake2_256.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha2_256hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha256.digest(data)
    var length = if sha256.sizeDigest > len(output): len(output)
                 else: sha256.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha2_512hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha512.digest(data)
    var length = if sha512.sizeDigest > len(output): len(output)
                 else: sha512.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha3_224hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha3_224.digest(data)
    var length = if sha3_224.sizeDigest > len(output): len(output)
                 else: sha3_224.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha3_256hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha3_256.digest(data)
    var length = if sha3_256.sizeDigest > len(output): len(output)
                 else: sha3_256.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha3_384hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha3_384.digest(data)
    var length = if sha3_384.sizeDigest > len(output): len(output)
                 else: sha3_384.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc sha3_512hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = sha3_512.digest(data)
    var length = if sha3_512.sizeDigest > len(output): len(output)
                 else: sha3_512.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc keccak_224hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = keccak224.digest(data)
    var length = if keccak224.sizeDigest > len(output): len(output)
                 else: keccak224.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc keccak_256hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = keccak256.digest(data)
    var length = if keccak256.sizeDigest > len(output): len(output)
                 else: keccak256.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc keccak_384hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = keccak384.digest(data)
    var length = if keccak384.sizeDigest > len(output): len(output)
                 else: keccak384.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc keccak_512hash(data: openarray[byte], output: var openarray[byte]) =
  if len(output) > 0:
    var digest = keccak512.digest(data)
    var length = if keccak512.sizeDigest > len(output): len(output)
                 else: keccak512.sizeDigest
    copyMem(addr output[0], addr digest.data[0], length)

proc shake_128hash(data: openarray[byte], output: var openarray[byte]) =
  var sctx: shake128
  if len(output) > 0:
    sctx.init()
    sctx.update(cast[ptr uint8](unsafeAddr data[0]), uint(len(data)))
    sctx.xof()
    discard sctx.output(addr output[0], uint(len(output)))
    sctx.clear()

proc shake_256hash(data: openarray[byte], output: var openarray[byte]) =
  var sctx: shake256
  if len(output) > 0:
    sctx.init()
    sctx.update(cast[ptr uint8](unsafeAddr data[0]), uint(len(data)))
    sctx.xof()
    discard sctx.output(addr output[0], uint(len(output)))
    sctx.clear()

const
  HashesList = [
    MHash(name: "identity", code: 0x00, size: 0, coder: identhash),
    MHash(name: "dbl-sha2-256", code: 0x56, size: sha256.sizeDigest,
          coder: dblsha2_256hash
    ),
    MHash(name: "sha2-256", code: 0x12, size: sha256.sizeDigest,
          coder: sha2_256hash
    ),
    MHash(name: "sha2-512", code: 0x13, size: sha512.sizeDigest,
          coder: sha2_512hash
    ),
    MHash(name: "sha3-224", code: 0x17, size: sha3_224.sizeDigest,
          coder: sha3_224hash
    ),
    MHash(name: "sha3-256", code: 0x16, size: sha3_256.sizeDigest,
          coder: sha3_256hash
    ),
    MHash(name: "sha3-384", code: 0x15, size: sha3_384.sizeDigest,
          coder: sha3_384hash
    ),
    MHash(name: "sha3-512", code: 0x14, size: sha3_512.sizeDigest,
          coder: sha3_512hash
    ),
    MHash(name: "shake-128", code: 0x18, size: 32, coder: shake_128hash),
    MHash(name: "shake-256", code: 0x19, size: 64, coder: shake_256hash),
    MHash(name: "keccak-224", code: 0x1A, size: keccak_224.sizeDigest,
          coder: keccak_224hash
    ),
    MHash(name: "keccak-256", code: 0x1B, size: keccak_256.sizeDigest,
          coder: keccak_256hash
    ),
    MHash(name: "keccak-384", code: 0x1C, size: keccak_384.sizeDigest,
          coder: keccak_384hash
    ),
    MHash(name: "keccak-512", code: 0x1D, size: keccak_512.sizeDigest,
          coder: keccak_512hash
    ),
    MHash(name: "blake2b-8", code: 0xB201, size: 1, coder: blake2Bhash),
    MHash(name: "blake2b-16", code: 0xB202, size: 2, coder: blake2Bhash),
    MHash(name: "blake2b-24", code: 0xB203, size: 3, coder: blake2Bhash),
    MHash(name: "blake2b-32", code: 0xB204, size: 4, coder: blake2Bhash),
    MHash(name: "blake2b-40", code: 0xB205, size: 5, coder: blake2Bhash),
    MHash(name: "blake2b-48", code: 0xB206, size: 6, coder: blake2Bhash),
    MHash(name: "blake2b-56", code: 0xB207, size: 7, coder: blake2Bhash),
    MHash(name: "blake2b-64", code: 0xB208, size: 8, coder: blake2Bhash),
    MHash(name: "blake2b-72", code: 0xB209, size: 9, coder: blake2Bhash),
    MHash(name: "blake2b-80", code: 0xB20A, size: 10, coder: blake2Bhash),
    MHash(name: "blake2b-88", code: 0xB20B, size: 11, coder: blake2Bhash),
    MHash(name: "blake2b-96", code: 0xB20C, size: 12, coder: blake2Bhash),
    MHash(name: "blake2b-104", code: 0xB20D, size: 13, coder: blake2Bhash),
    MHash(name: "blake2b-112", code: 0xB20E, size: 14, coder: blake2Bhash),
    MHash(name: "blake2b-120", code: 0xB20F, size: 15, coder: blake2Bhash),
    MHash(name: "blake2b-128", code: 0xB210, size: 16, coder: blake2Bhash),
    MHash(name: "blake2b-136", code: 0xB211, size: 17, coder: blake2Bhash),
    MHash(name: "blake2b-144", code: 0xB212, size: 18, coder: blake2Bhash),
    MHash(name: "blake2b-152", code: 0xB213, size: 19, coder: blake2Bhash),
    MHash(name: "blake2b-160", code: 0xB214, size: 20, coder: blake2Bhash),
    MHash(name: "blake2b-168", code: 0xB215, size: 21, coder: blake2Bhash),
    MHash(name: "blake2b-176", code: 0xB216, size: 22, coder: blake2Bhash),
    MHash(name: "blake2b-184", code: 0xB217, size: 23, coder: blake2Bhash),
    MHash(name: "blake2b-192", code: 0xB218, size: 24, coder: blake2Bhash),
    MHash(name: "blake2b-200", code: 0xB219, size: 25, coder: blake2Bhash),
    MHash(name: "blake2b-208", code: 0xB21A, size: 26, coder: blake2Bhash),
    MHash(name: "blake2b-216", code: 0xB21B, size: 27, coder: blake2Bhash),
    MHash(name: "blake2b-224", code: 0xB21C, size: 28, coder: blake2Bhash),
    MHash(name: "blake2b-232", code: 0xB21D, size: 29, coder: blake2Bhash),
    MHash(name: "blake2b-240", code: 0xB21E, size: 30, coder: blake2Bhash),
    MHash(name: "blake2b-248", code: 0xB21F, size: 31, coder: blake2Bhash),
    MHash(name: "blake2b-256", code: 0xB220, size: 32, coder: blake2Bhash),
    MHash(name: "blake2b-264", code: 0xB221, size: 33, coder: blake2Bhash),
    MHash(name: "blake2b-272", code: 0xB222, size: 34, coder: blake2Bhash),
    MHash(name: "blake2b-280", code: 0xB223, size: 35, coder: blake2Bhash),
    MHash(name: "blake2b-288", code: 0xB224, size: 36, coder: blake2Bhash),
    MHash(name: "blake2b-296", code: 0xB225, size: 37, coder: blake2Bhash),
    MHash(name: "blake2b-304", code: 0xB226, size: 38, coder: blake2Bhash),
    MHash(name: "blake2b-312", code: 0xB227, size: 39, coder: blake2Bhash),
    MHash(name: "blake2b-320", code: 0xB228, size: 40, coder: blake2Bhash),
    MHash(name: "blake2b-328", code: 0xB229, size: 41, coder: blake2Bhash),
    MHash(name: "blake2b-336", code: 0xB22A, size: 42, coder: blake2Bhash),
    MHash(name: "blake2b-344", code: 0xB22B, size: 43, coder: blake2Bhash),
    MHash(name: "blake2b-352", code: 0xB22C, size: 44, coder: blake2Bhash),
    MHash(name: "blake2b-360", code: 0xB22D, size: 45, coder: blake2Bhash),
    MHash(name: "blake2b-368", code: 0xB22E, size: 46, coder: blake2Bhash),
    MHash(name: "blake2b-376", code: 0xB22F, size: 47, coder: blake2Bhash),
    MHash(name: "blake2b-384", code: 0xB230, size: 48, coder: blake2Bhash),
    MHash(name: "blake2b-392", code: 0xB231, size: 49, coder: blake2Bhash),
    MHash(name: "blake2b-400", code: 0xB232, size: 50, coder: blake2Bhash),
    MHash(name: "blake2b-408", code: 0xB233, size: 51, coder: blake2Bhash),
    MHash(name: "blake2b-416", code: 0xB234, size: 52, coder: blake2Bhash),
    MHash(name: "blake2b-424", code: 0xB235, size: 53, coder: blake2Bhash),
    MHash(name: "blake2b-432", code: 0xB236, size: 54, coder: blake2Bhash),
    MHash(name: "blake2b-440", code: 0xB237, size: 55, coder: blake2Bhash),
    MHash(name: "blake2b-448", code: 0xB238, size: 56, coder: blake2Bhash),
    MHash(name: "blake2b-456", code: 0xB239, size: 57, coder: blake2Bhash),
    MHash(name: "blake2b-464", code: 0xB23A, size: 58, coder: blake2Bhash),
    MHash(name: "blake2b-472", code: 0xB23B, size: 59, coder: blake2Bhash),
    MHash(name: "blake2b-480", code: 0xB23C, size: 60, coder: blake2Bhash),
    MHash(name: "blake2b-488", code: 0xB23D, size: 61, coder: blake2Bhash),
    MHash(name: "blake2b-496", code: 0xB23E, size: 62, coder: blake2Bhash),
    MHash(name: "blake2b-504", code: 0xB23F, size: 63, coder: blake2Bhash),
    MHash(name: "blake2b-512", code: 0xB240, size: 64, coder: blake2Bhash),
    MHash(name: "blake2s-8", code: 0xB241, size: 1, coder: blake2Shash),
    MHash(name: "blake2s-16", code: 0xB242, size: 2, coder: blake2Shash),
    MHash(name: "blake2s-24", code: 0xB243, size: 3, coder: blake2Shash),
    MHash(name: "blake2s-32", code: 0xB244, size: 4, coder: blake2Shash),
    MHash(name: "blake2s-40", code: 0xB245, size: 5, coder: blake2Shash),
    MHash(name: "blake2s-48", code: 0xB246, size: 6, coder: blake2Shash),
    MHash(name: "blake2s-56", code: 0xB247, size: 7, coder: blake2Shash),
    MHash(name: "blake2s-64", code: 0xB248, size: 8, coder: blake2Shash),
    MHash(name: "blake2s-72", code: 0xB249, size: 9, coder: blake2Shash),
    MHash(name: "blake2s-80", code: 0xB24A, size: 10, coder: blake2Shash),
    MHash(name: "blake2s-88", code: 0xB24B, size: 11, coder: blake2Shash),
    MHash(name: "blake2s-96", code: 0xB24C, size: 12, coder: blake2Shash),
    MHash(name: "blake2s-104", code: 0xB24D, size: 13, coder: blake2Shash),
    MHash(name: "blake2s-112", code: 0xB24E, size: 14, coder: blake2Shash),
    MHash(name: "blake2s-120", code: 0xB24F, size: 15, coder: blake2Shash),
    MHash(name: "blake2s-128", code: 0xB250, size: 16, coder: blake2Shash),
    MHash(name: "blake2s-136", code: 0xB251, size: 17, coder: blake2Shash),
    MHash(name: "blake2s-144", code: 0xB252, size: 18, coder: blake2Shash),
    MHash(name: "blake2s-152", code: 0xB253, size: 19, coder: blake2Shash),
    MHash(name: "blake2s-160", code: 0xB254, size: 20, coder: blake2Shash),
    MHash(name: "blake2s-168", code: 0xB255, size: 21, coder: blake2Shash),
    MHash(name: "blake2s-176", code: 0xB256, size: 22, coder: blake2Shash),
    MHash(name: "blake2s-184", code: 0xB257, size: 23, coder: blake2Shash),
    MHash(name: "blake2s-192", code: 0xB258, size: 24, coder: blake2Shash),
    MHash(name: "blake2s-200", code: 0xB259, size: 25, coder: blake2Shash),
    MHash(name: "blake2s-208", code: 0xB25A, size: 26, coder: blake2Shash),
    MHash(name: "blake2s-216", code: 0xB25B, size: 27, coder: blake2Shash),
    MHash(name: "blake2s-224", code: 0xB25C, size: 28, coder: blake2Shash),
    MHash(name: "blake2s-232", code: 0xB25D, size: 29, coder: blake2Shash),
    MHash(name: "blake2s-240", code: 0xB25E, size: 30, coder: blake2Shash),
    MHash(name: "blake2s-248", code: 0xB25F, size: 31, coder: blake2Shash),
    MHash(name: "blake2s-256", code: 0xB260, size: 32, coder: blake2Shash)
  ]

proc initMultiHashNameTable(): Table[string, MHash] {.compileTime.} =
  result = initTable[string, MHash]()
  for item in HashesList:
    result[item.name] = item

proc initMultiHashCodeTable(): Table[int, MHash] {.compileTime.} =
  result = initTable[int, MHash]()
  for item in HashesList:
    result[item.code] = item

const
  CodeHashes = initMultiHashCodeTable()
  NameHashes = initMultiHashNameTable()

proc multihashName*(code: int): string =
  ## Returns MultiHash digest name from its code.
  let hash = CodeHashes.getOrDefault(code)
  if isNil(hash.coder):
    raise newException(MultiHashError, "Hash not supported")
  else:
    result = hash.name

proc multihashCode*(name: string): int =
  ## Returns MultiHash digest code from its name.
  let hash = NameHashes.getOrDefault(name)
  if isNil(hash.coder):
    raise newException(MultiHashError, "Hash not supported")
  else:
    result = hash.code

proc digestImplWithHash(hash: MHash, data: openarray[byte]): MultiHash =
  var buffer: array[MaxHashSize, byte]
  result.data = initVBuffer()
  result.code = hash.code
  result.data.writeVarint(uint(hash.code))
  if hash.size == 0:
    result.data.writeVarint(uint(len(data)))
    result.dpos = len(result.data.buffer)
    result.data.writeArray(data)
    result.size = len(data)
  else:
    result.data.writeVarint(uint(hash.size))
    result.dpos = len(result.data.buffer)
    hash.coder(data, buffer.toOpenArray(0, hash.size - 1))
    result.data.writeArray(buffer.toOpenArray(0, hash.size - 1))
    result.size = hash.size

proc digestImplWithoutHash(hash: MHash, data: openarray[byte]): MultiHash =
  result.data = initVBuffer()
  result.code = hash.code
  result.size = len(data)
  result.data.writeVarint(uint(hash.code))
  result.data.writeVarint(uint(len(data)))
  result.dpos = len(result.data.buffer)
  result.data.writeArray(data)

proc digest*(mhtype: typedesc[MultiHash], hashname: string,
             data: openarray[byte]): MultiHash {.inline.} =
  ## Perform digest calculation using hash algorithm with name ``hashname`` on
  ## data array ``data``.
  let hash = NameHashes.getOrDefault(hashname)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  result = digestImplWithHash(hash, data)

proc digest*(mhtype: typedesc[MultiHash], hashcode: int,
             data: openarray[byte]): MultiHash {.inline.} =
  ## Perform digest calculation using hash algorithm with code ``hashcode`` on
  ## data array ``data``.
  let hash = CodeHashes.getOrDefault(hashcode)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  result = digestImplWithHash(hash, data)

proc init*[T](mhtype: typedesc[MultiHash], hashname: string,
                mdigest: MDigest[T]): MultiHash {.inline.} =
  ## Create MultiHash from nimcrypto's `MDigest` object and hash algorithm name
  ## ``hashname``.
  let hash = NameHashes.getOrDefault(hashname)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  if hash.size != len(mdigest.data):
    raise newException(MultiHashError, "Incorrect MDigest[T] size")
  result = digestImplWithoutHash(hash, mdigest.data)

proc init*[T](mhtype: typedesc[MultiHash], hashcode: int,
              mdigest: MDigest[T]): MultiHash {.inline.} =
  ## Create MultiHash from nimcrypto's `MDigest` and hash algorithm code
  ## ``hashcode``.
  let hash = CodeHashes.getOrDefault(hashcode)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  if (hash.size != 0) and (hash.size != len(mdigest.data)):
    raise newException(MultiHashError, "Incorrect MDigest[T] size")
  result = digestImplWithoutHash(hash, mdigest.data)

proc init*(mhtype: typedesc[MultiHash], hashname: string,
           bdigest: openarray[byte]): MultiHash {.inline.} =
  ## Create MultiHash from array of bytes ``bdigest`` and hash algorithm code
  ## ``hashcode``.
  let hash = NameHashes.getOrDefault(hashname)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  if (hash.size != 0) and (hash.size != len(bdigest)):
    raise newException(MultiHashError, "Incorrect bdigest size")
  result = digestImplWithoutHash(hash, bdigest)

proc init*(mhtype: typedesc[MultiHash], hashcode: int,
           bdigest: openarray[byte]): MultiHash {.inline.} =
  ## Create MultiHash from array of bytes ``bdigest`` and hash algorithm code
  ## ``hashcode``.
  let hash = CodeHashes.getOrDefault(hashcode)
  if isNil(hash.coder):
    raise newException(MultihashError, "Hash not supported")
  if (hash.size != 0) and (hash.size != len(bdigest)):
    raise newException(MultiHashError, "Incorrect bdigest size")
  result = digestImplWithoutHash(hash, bdigest)

proc decode*(mhtype: typedesc[MultiHash], data: openarray[byte],
             mhash: var MultiHash): int =
  ## Decode MultiHash value from array of bytes ``data``.
  ##
  ## On success decoded MultiHash will be stored into ``mhash`` and number of
  ## bytes consumed will be returned.
  ##
  ## On error ``-1`` will be returned.
  var code, size: uint64
  var res, dpos: int
  if len(data) < 2:
    return -1
  var vb = initVBuffer(data)
  if vb.isEmpty():
    return -1
  res = vb.readVarint(code)
  if res == -1:
    return -1
  dpos += res
  res = vb.readVarint(size)
  if res == -1:
    return -1
  dpos += res
  if size > 0x7FFF_FFFF'u64:
    return -1
  let hash = CodeHashes.getOrDefault(int(code))
  if isNil(hash.coder):
    return -1
  if (hash.size != 0) and (hash.size != int(size)):
    return -1
  if not vb.isEnough(int(size)):
    return -1
  mhash = MultiHash.init(int(code),
                         vb.buffer.toOpenArray(vb.offset,
                                               vb.offset + int(size) - 1))
  result = vb.offset + int(size)

proc init*(mhtype: typedesc[MultiHash],
           data: openarray[byte]): MultiHash {.inline.} =
  ## Create MultiHash from bytes array ``data``.
  if MultiHash.decode(data, result) == -1:
    raise newException(MultihashError, "Incorrect MultiHash binary format")

proc init*(mhtype: typedesc[MultiHash], data: string): MultiHash {.inline.} =
  ## Create MultiHash from hexadecimal string representation ``data``.
  if MultiHash.decode(fromHex(data), result) == -1:
    raise newException(MultihashError, "Incorrect MultiHash binary format")

proc cmp(a: openarray[byte], b: openarray[byte]): bool {.inline.} =
  if len(a) != len(b):
    return false
  var n = len(a)
  var res, diff: int
  while n > 0:
    dec(n)
    diff = int(a[n]) - int(b[n])
    res = (res and -not(diff)) or diff
  result = (res == 0)

proc `==`*[T](mh: MultiHash, mdigest: MDigest[T]): bool =
  ## Compares MultiHash with nimcrypto's MDigest[T], returns ``true`` if
  ## hashes are equal, ``false`` otherwise.
  if mh.dpos == 0:
    return false
  if len(mdigest.data) != mh.size:
    return false
  result = cmp(mh.data.buffer.toOpenArray(mh.dpos, mh.dpos + mh.size - 1),
               mdigest.data.toOpenArray(0, len(mdigest.data) - 1))

proc `==`*[T](mdigest: MDigest[T], mh: MultiHash): bool {.inline.} =
  ## Compares MultiHash with nimcrypto's MDigest[T], returns ``true`` if
  ## hashes are equal, ``false`` otherwise.  
  result = `==`(mh, mdigest)

proc `==`*(a, b: MultiHash): bool =
  ## Compares MultiHashes ``a`` and ``b``, returns ``true`` if
  ## hashes are equal, ``false`` otherwise.
  if a.dpos == 0 and b.dpos == 0:
    return true
  if a.code != b.code:
    return false
  if a.size != b.size:
    return false
  result = cmp(a.data.buffer.toOpenArray(a.dpos, a.dpos + a.size - 1),
               b.data.buffer.toOpenArray(b.dpos, b.dpos + b.size - 1))

proc hex*(value: MultiHash): string =
  ## Return hexadecimal string representation of MultiHash ``value``.
  result = $(value.data)

proc base58*(value: MultiHash): string =
  ## Return Base58 encoded string representation of MultiHash ``value``.
  result = Base58.encode(value.data.buffer)

proc `$`*(value: MultiHash): string =
  ## Return string representation of MultiHash ``value``.
  let digest = toHex(value.data.buffer.toOpenArray(value.dpos,
                                                   value.dpos + value.size - 1))
  result = multihashName(value.code) & "/" & digest
