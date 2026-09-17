# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Kademlia's typed byte domains, kept separate from the protobuf message
## definitions so both ``types`` and ``protobuf`` can depend on them.

import std/hashes
import chronicles, stew/arrayOps
import ../../utils/shortlog

const IdLength* = 32 # 256-bit IDs

type
  Key* = distinct seq[byte]
    ## A Kademlia routing key. Construct with ``Key.init`` or ``Key.fromBytes``.
  Value* = distinct seq[byte]
    ## A Kademlia record value. Construct with ``Value.init`` or ``Value.fromBytes``.

func init*(T: typedesc[Key], bytes: openArray[byte]): Key =
  ## Key of `IdLength` bytes holding `bytes`, zero-padded.
  var buf: array[IdLength, byte]
  discard buf.copyFrom(bytes)
  Key(@buf)

template fromBytes*(T: typedesc[Key], bytes: sink seq[byte]): Key =
  ## Preserves raw Kademlia key bytes received from a wire message.
  Key(bytes)

template toBytes*(key: Key): seq[byte] =
  ## Returns the raw bytes used by Kademlia and its wire protocol.
  seq[byte](key)

proc len*(key: Key): int {.inline.} =
  seq[byte](key).len

proc `[]`*(key: Key, index: int): byte {.inline.} =
  seq[byte](key)[index]

proc `[]=`*(key: var Key, index: int, value: byte) {.inline.} =
  seq[byte](key)[index] = value

proc `==`*(a, b: Key): bool {.borrow.}
proc hash*(key: Key): Hash {.borrow.}

proc `$`*(key: Key): string =
  $seq[byte](key)

template init*(T: typedesc[Value], bytes: openArray[byte]): Value =
  Value(@bytes)

template fromBytes*(T: typedesc[Value], bytes: sink seq[byte]): Value =
  ## Preserves raw Kademlia value bytes received from a wire message.
  Value(bytes)

template toBytes*(value: Value): seq[byte] =
  ## Returns the raw bytes used by Kademlia and its wire protocol.
  seq[byte](value)

proc len*(value: Value): int {.inline.} =
  seq[byte](value).len

proc `[]`*(value: Value, index: int): byte {.inline.} =
  seq[byte](value)[index]

proc `[]=`*(value: var Value, index: int, byte: byte) {.inline.} =
  seq[byte](value)[index] = byte

proc `==`*(a, b: Value): bool {.borrow.}
proc hash*(value: Value): Hash {.borrow.}

proc `$`*(value: Value): string =
  $seq[byte](value)

func shortLog*(v: Value): string =
  v.toBytes().shortLog

func shortLog*(k: Key): string =
  k.toBytes().shortLog

chronicles.formatIt(Value):
  it.shortLog

chronicles.formatIt(Key):
  it.shortLog
