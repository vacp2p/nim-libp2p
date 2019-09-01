## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

type 
  LPStream* = ref object of RootObj
    closed*: bool

  LPStreamError* = object of CatchableError
  LPStreamIncompleteError* = object of LPStreamError
  LPStreamIncorrectError* = object of Defect
  LPStreamLimitError* = object of LPStreamError
  LPStreamReadError* = object of LPStreamError
    par*: ref Exception
  LPStreamWriteError* = object of LPStreamError
    par*: ref Exception

proc newLPStreamReadError*(p: ref Exception): ref Exception {.inline.} =
  var w = newException(LPStreamReadError, "Read stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamWriteError*(p: ref Exception): ref Exception {.inline.} =
  var w = newException(LPStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamIncompleteError*(): ref Exception {.inline.} =
  result = newException(LPStreamIncompleteError, "Incomplete data received")

proc newLPStreamLimitError*(): ref Exception {.inline.} =
  result = newException(LPStreamLimitError, "Buffer limit reached")

proc newLPStreamIncorrectError*(m: string): ref Exception {.inline.} =
  result = newException(LPStreamIncorrectError, m)

method read*(s: LPStream, n = -1): Future[seq[byte]]
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method readExactly*(s: LPStream, pbytes: pointer, nbytes: int): Future[void]
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method readLine*(s: LPStream, limit = 0, sep = "\r\n"): Future[string]
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method readOnce*(s: LPStream, pbytes: pointer, nbytes: int): Future[int]
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method readUntil*(s: LPStream,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): Future[int]
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method write*(s: LPStream, pbytes: pointer, nbytes: int)
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method write*(s: LPStream, msg: string, msglen = -1)
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method write*(s: LPStream, msg: seq[byte], msglen = -1)
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")

method close*(s: LPStream)
  {.base, async, gcsafe.} =
  assert(false, "not implemented!")
