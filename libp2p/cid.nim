## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implementes CID (Content IDentifier).
import tables
import multibase, multicodec, multihash, vbuffer, varint
import stew/base58

type
  CidStatus* {.pure.} = enum
    Error, Success, Incorrect, Overrun

  CidVersion* = enum
    CIDvIncorrect, CIDv0, CIDv1, CIDvReserved

  Cid* = object
    cidver*: CidVersion
    mcodec*: MultiCodec
    hpos*: int
    data*: VBuffer

  CidError* = object of CatchableError

const
  ContentIdsList = [
    multiCodec("raw"),
    multiCodec("dag-pb"),
    multiCodec("dag-cbor"),
    multiCodec("dag-json"),
    multiCodec("git-raw"),
    multiCodec("eth-block"),
    multiCodec("eth-block-list"),
    multiCodec("eth-tx-trie"),
    multiCodec("eth-tx"),
    multiCodec("eth-tx-receipt-trie"),
    multiCodec("eth-tx-receipt"),
    multiCodec("eth-state-trie"),
    multiCodec("eth-account-snapshot"),
    multiCodec("eth-storage-trie"),
    multiCodec("bitcoin-block"),
    multiCodec("bitcoin-tx"),
    multiCodec("zcash-block"),
    multiCodec("zcash-tx"),
    multiCodec("stellar-block"),
    multiCodec("stellar-tx"),
    multiCodec("decred-block"),
    multiCodec("decred-tx"),
    multiCodec("dash-block"),
    multiCodec("dash-tx"),
    multiCodec("torrent-info"),
    multiCodec("torrent-file"),
    multiCodec("ed25519-pub")
  ]

proc initCidCodeTable(): Table[int, MultiCodec] {.compileTime.} =
  result = initTable[int, MultiCodec]()
  for item in ContentIdsList:
    result[int(item)] = item

const
  CodeContentIds = initCidCodeTable()

proc decode(data: openarray[byte], cid: var Cid): CidStatus =
  if len(data) == 34:
    if data[0] == 0x12'u8 and data[1] == 0x20'u8:
      cid.cidver = CIDv0
      cid.mcodec = multiCodec("dag-pb")
      cid.hpos = 0
      cid.data = initVBuffer(data)
      result = CidStatus.Success
  if cid.cidver == CIDvIncorrect:
    var version, codec: uint64
    var res, offset: int
    var vb = initVBuffer(data)
    if vb.isEmpty():
      return CidStatus.Incorrect
    res = vb.readVarint(version)
    if res == -1:
      return CidStatus.Incorrect
    offset += res
    if version != 1'u64:
      return CidStatus.Incorrect
    res = vb.readVarint(codec)
    if res == -1:
      return CidStatus.Incorrect
    offset += res
    var mcodec = CodeContentIds.getOrDefault(cast[int](codec),
                                             InvalidMultiCodec)
    if mcodec == InvalidMultiCodec:
      return CidStatus.Incorrect
    if not MultiHash.validate(vb.buffer.toOpenArray(vb.offset,
                                                    vb.buffer.high)):
      return CidStatus.Incorrect
    vb.finish()
    cid.cidver = CIDv1
    cid.mcodec = mcodec
    cid.hpos = offset
    cid.data = vb
    result = CidStatus.Success

proc decode(data: openarray[char], cid: var Cid): CidStatus =
  var buffer: seq[byte]
  var plen = 0
  if len(data) < 2:
    return CidStatus.Incorrect
  if len(data) == 46:
    if data[0] == 'Q' and data[1] == 'm':
      buffer = newSeq[byte](BTCBase58.decodedLength(len(data)))
      if BTCBase58.decode(data, buffer, plen) != Base58Status.Success:
        return CidStatus.Incorrect
      buffer.setLen(plen)
  if len(buffer) == 0:
    let length = MultiBase.decodedLength(data[0], len(data))
    if length == -1:
      return CidStatus.Incorrect
    buffer = newSeq[byte](length)
    if MultiBase.decode(data, buffer, plen) != MultiBaseStatus.Success:
      return CidStatus.Incorrect
    buffer.setLen(plen)
    if buffer[0] == 0x12'u8:
      return CidStatus.Incorrect
  result = decode(buffer, cid)

proc validate*(ctype: typedesc[Cid], data: openarray[byte]): bool =
  ## Returns ``true`` is data has valid binary CID representation.
  var version, codec: uint64
  var res: VarintResult[void]
  if len(data) < 2:
    return false
  let last = data.high
  if len(data) == 34:
    if data[0] == 0x12'u8 and data[1] == 0x20'u8:
      return true
  var offset = 0
  var length = 0
  res = LP.getUVarint(data.toOpenArray(offset, last), length, version)
  if res.isErr():
    return false
  if version != 1'u64:
    return false
  offset += length
  if offset >= len(data):
    return false
  res = LP.getUVarint(data.toOpenArray(offset, last), length, codec)
  if res.isErr():
    return false
  var mcodec = CodeContentIds.getOrDefault(cast[int](codec), InvalidMultiCodec)
  if mcodec == InvalidMultiCodec:
    return false
  if not MultiHash.validate(data.toOpenArray(offset, last)):
    return false
  result = true

proc mhash*(cid: Cid): MultiHash =
  ## Returns MultiHash part of CID.
  if cid.cidver notin {CIDv0, CIDv1}:
    raise newException(CidError, "Incorrect CID!")
  result = MultiHash.init(
    cid.data.buffer.toOpenArray(cid.hpos, cid.data.high)).tryGet()

proc contentType*(cid: Cid): MultiCodec =
  ## Returns content type part of CID
  if cid.cidver notin {CIDv0, CIDv1}:
    raise newException(CidError, "Incorrect CID!")
  result = cid.mcodec

proc version*(cid: Cid): CidVersion =
  ## Returns CID version
  result = cid.cidver

proc init*[T: char|byte](ctype: typedesc[Cid], data: openarray[T]): Cid =
  ## Create new content identifier using array of bytes or string ``data``.
  if decode(data, result) != CidStatus.Success:
    raise newException(CidError, "Incorrect CID!")

proc init*(ctype: typedesc[Cid], version: CidVersion, content: MultiCodec,
           hash: MultiHash): Cid =
  ## Create new content identifier using content type ``content`` and
  ## MultiHash ``hash`` using version ``version``.
  ##
  ## To create ``CIDv0`` you need to use:
  ## Cid.init(CIDv0, multiCodec("dag-pb"), MultiHash.digest("sha2-256", data))
  ##
  ## All other encodings and hashes are not supported by CIDv0.
  result.cidver = version
  
  if version == CIDv0:
    if content != multiCodec("dag-pb"):
      raise newException(CidError,
                         "CIDv0 supports only `dag-pb` content type!")
    result.data = initVBuffer()
    if hash.mcodec != multiCodec("sha2-256"):
      raise newException(CidError,
                         "CIDv0 supports only `sha2-256` hash digest!")
    result.mcodec = content
    result.data.write(hash)
    result.data.finish()
  elif version == CIDv1:
    let mcodec = CodeContentIds.getOrDefault(cast[int](content),
                                             InvalidMultiCodec)
    if mcodec == InvalidMultiCodec:
      raise newException(CidError, "Incorrect content type")
    result.mcodec = mcodec
    result.data = initVBuffer()
    result.data.writeVarint(cast[uint64](1))
    result.data.write(mcodec)
    result.hpos = len(result.data.buffer)
    result.data.write(hash)
    result.data.finish()
  else:
    raise newException(CidError, "CID version is not supported" & $version)

proc `==`*(a: Cid, b: Cid): bool =
  ## Compares content identifiers ``a`` and ``b``, returns ``true`` if hashes
  ## are equal, ``false`` otherwise.
  if a.mcodec == b.mcodec:
    var ah, bh: MultiHash
    if MultiHash.decode(
      a.data.buffer.toOpenArray(a.hpos, a.data.high), ah).isErr:
      return false
    if MultiHash.decode(
      b.data.buffer.toOpenArray(b.hpos, b.data.high), bh).isErr:
      return false
    result = (ah == bh)

proc base58*(cid: Cid): string =
  ## Get BASE58 encoded string representation of content identifier ``cid``.
  result = BTCBase58.encode(cid.data.buffer)

proc hex*(cid: Cid): string =
  ## Get hexadecimal string representation of content identifier ``cid``.
  result = $(cid.data)

proc repr*(cid: Cid): string =
  ## Get string representation of content identifier ``cid``.
  result = $(cid.cidver)
  result.add("/")
  result.add($(cid.mcodec))
  result.add("/")
  result.add($(cid.mhash()))

proc write*(vb: var VBuffer, cid: Cid) {.inline.} =
  ## Write CID value ``cid`` to buffer ``vb``.
  vb.writeArray(cid.data.buffer)

proc encode*(mbtype: typedesc[MultiBase], encoding: string,
             cid: Cid): string {.inline.} =
  ## Get MultiBase encoded representation of ``cid`` using encoding
  ## ``encoding``.
  result = MultiBase.encode(encoding, cid.data.buffer).tryGet()

proc `$`*(cid: Cid): string =
  ## Return official string representation of content identifier ``cid``.
  if cid.cidver == CIDv0:
    result = BTCBase58.encode(cid.data.buffer)
  elif cid.cidver == CIDv1:
    result = Multibase.encode("base58btc", cid.data.buffer).tryGet()
