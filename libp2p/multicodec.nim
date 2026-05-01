# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements MultiCodec.

{.push raises: [].}
{.used.}

import tables, hashes
import macros
import strutils
import vbuffer
import results
import utility
export results

const libp2p_multicodec_exts* {.strdefine.} = ""

## List of officially supported codecs is generated from:
## https://github.com/multiformats/multicodec/blob/master/table.csv
## Run `nimble gen_multicodec` to regenerate multicodec_table.nim.
include ./multicodec_table

## Custom codecs not found in the upstream multicodec CSV.
const MultiCodecListCustom = [
  ("libp2p-custom-peer-record", 0x300000), # not in multicodec list
]

type
  MultiCodec* = distinct int
  MultiCodecError* = enum
    MultiCodecNotSupported

const InvalidMultiCodec* = MultiCodec(-1)

proc initLists(
    codecs: seq[tuple[name: string, code: int]]
): (Table[string, int], Table[int, string]) {.compileTime.} =
  var nameCodecs: Table[string, int]
  var codeCodecs: Table[int, string]

  for (name, code) in codecs:
    if name in nameCodecs:
      error("Codec name '" & name & "' is already used. Name must be unique.")
    nameCodecs[name] = code

    if code in codeCodecs:
      error("Codec code 0x" & code.toHex(4) & " is already used. Code must be unique.")
    codeCodecs[code] = name

  return (nameCodecs, codeCodecs)

when libp2p_multicodec_exts != "":
  includeFile(libp2p_multicodec_exts)
  const (NameCodecs, CodeCodecs) =
    initLists(@MultiCodecList & @MultiCodecListCustom & @CodecExts)
else:
  const (NameCodecs, CodeCodecs) =
    initLists(@MultiCodecList & @MultiCodecListCustom)

proc multiCodec*(name: string): MultiCodec {.compileTime.} =
  ## Generate MultiCodec from string ``name`` at compile time.
  let code = NameCodecs.getOrDefault(name, -1)
  doAssert(code != -1)
  MultiCodec(code)

proc multiCodec*(code: int): MultiCodec {.compileTime.} =
  ## Generate MultiCodec from integer ``code`` at compile time.
  let name = CodeCodecs.getOrDefault(code, "")
  doAssert(name != "")
  MultiCodec(code)

proc `$`*(mc: MultiCodec): string =
  ## Returns string representation of MultiCodec ``mc``.
  let name = CodeCodecs.getOrDefault(int(mc), "")
  doAssert(name != "")
  name

proc `==`*(mc: MultiCodec, name: string): bool {.inline.} =
  ## Compares MultiCodec ``mc`` with string ``name``.
  let mcname = CodeCodecs.getOrDefault(int(mc), "")
  if mcname == "":
    return false
  result = (mcname == name)

proc `==`*(mc: MultiCodec, code: int): bool {.inline.} =
  ## Compares MultiCodec ``mc`` with integer ``code``.
  (int(mc) == code)

proc `==`*(a, b: MultiCodec): bool =
  ## Returns ``true`` if MultiCodecs ``a`` and ``b`` are equal.
  int(a) == int(b)

proc hash*(m: MultiCodec): Hash {.inline.} =
  ## Hash procedure for tables.
  hash(int(m))

proc codec*(mt: typedesc[MultiCodec], name: string): MultiCodec {.inline.} =
  ## Return MultiCodec from string representation ``name``.
  ## If ``name`` is not valid multicodec name, then ``InvalidMultiCodec`` will
  ## be returned.
  MultiCodec(NameCodecs.getOrDefault(name, -1))

proc codec*(mt: typedesc[MultiCodec], code: int): MultiCodec {.inline.} =
  ## Return MultiCodec from integer representation ``code``.
  ## If ``code`` is not valid multicodec code, then ``InvalidMultiCodec`` will
  ## be returned.
  let res = CodeCodecs.getOrDefault(code, "")
  if res == "":
    InvalidMultiCodec
  else:
    MultiCodec(code)

proc write*(vb: var VBuffer, mc: MultiCodec) {.inline.} =
  ## Write MultiCodec to buffer ``vb``.
  vb.writeVarint(cast[uint](mc))
