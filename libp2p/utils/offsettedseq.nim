# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sequtils

type OffsettedSeq*[T] = object
  s*: seq[T]
  offset*: int

proc initOffsettedSeq*[T](offset: int = 0): OffsettedSeq[T] =
  OffsettedSeq[T](s: newSeq[T](), offset: offset)

proc all*[T](o: OffsettedSeq[T], pred: proc(x: T): bool): bool =
  o.s.all(pred)

proc any*[T](o: OffsettedSeq[T], pred: proc(x: T): bool): bool =
  o.s.any(pred)

proc apply*[T](o: OffsettedSeq[T], op: proc(x: T)) =
  o.s.apply(pred)

proc apply*[T](o: OffsettedSeq[T], op: proc(x: T): T) =
  o.s.apply(pred)

proc apply*[T](o: OffsettedSeq[T], op: proc(x: var T)) =
  o.s.apply(pred)

func count*[T](o: OffsettedSeq[T], x: T): int =
  o.s.count(x)

proc flushIf*[T](o: OffsettedSeq[T], pred: proc(x: T): bool) =
  var i = 0
  for e in o.s:
    if not pred(e):
      break
    i.inc()
  if i > 0:
    o.s.delete(0 ..< i)
    o.offset.inc(i)

template flushIfIt*(o, pred: untyped) =
  var i = 0
  for it {.inject.} in o.s:
    if not pred:
      break
    i.inc()
  if i > 0:
    o.s.delete(0 ..< i)
    o.offset.inc(i)

proc add*[T](o: var OffsettedSeq[T], v: T) =
  o.s.add(v)

proc `[]`*[T](o: var OffsettedSeq[T], index: int): var T =
  o.s[index - o.offset]

iterator items*[T](o: OffsettedSeq[T]): T =
  for e in o.s:
    yield e

proc high*[T](o: OffsettedSeq[T]): int =
  o.s.high + o.offset

proc low*[T](o: OffsettedSeq[T]): int =
  o.s.low + o.offset
