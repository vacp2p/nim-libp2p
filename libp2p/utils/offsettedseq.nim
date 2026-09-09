# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

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
  o.s.apply(op)

proc apply*[T](o: var OffsettedSeq[T], op: proc(x: T): T) =
  o.s.apply(op)

proc apply*[T](o: var OffsettedSeq[T], op: proc(x: var T)) =
  o.s.apply(op)

func count*[T](o: OffsettedSeq[T], x: T): int =
  o.s.count(x)

template flushIfIt*(o, pred: untyped) =
  var i = 0
  for it {.inject.} in o.s:
    if not pred:
      break
    i.inc()
  if i > 0:
    o.s.delete(0 ..< i)
    o.offset.inc(i)

proc flushIf*[T](o: var OffsettedSeq[T], pred: proc(x: T): bool) =
  o.flushIfIt(pred(it))

proc add*[T](o: var OffsettedSeq[T], v: T) =
  o.s.add(v)

proc `[]`*[T](o: var OffsettedSeq[T], index: int): var T =
  o.s[index - o.offset]

iterator items*[T](o: OffsettedSeq[T]): T =
  for e in o.s:
    yield e

iterator mitems*[T](o: var OffsettedSeq[T]): var T =
  for e in o.s.mitems():
    yield e

proc high*[T](o: OffsettedSeq[T]): int =
  o.s.high + o.offset

proc low*[T](o: OffsettedSeq[T]): int =
  o.s.low + o.offset
