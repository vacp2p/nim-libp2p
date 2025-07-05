# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

type BytesView* = object
  data: seq[byte]
  rpos: int

proc init*(t: typedesc[BytesView], data: sink seq[byte]): BytesView =
  BytesView(data: data, rpos: 0)

func len*(v: BytesView): int {.inline.} =
  v.data.len - v.rpos

func consume*(v: var BytesView, n: int) {.inline.} =
  doAssert v.data.len >= v.rpos + n
  v.rpos += n

template toOpenArray*(v: BytesView, b, e: int): openArray[byte] =
  v.data.toOpenArray(v.rpos + b, v.rpos + e - b)

template data*(v: BytesView): openArray[byte] =
  v.data.toOpenArray(v.rpos, v.data.len - 1)
