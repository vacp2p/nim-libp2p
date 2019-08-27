## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

type LPStream* = ref object of RootObj
  closed*: bool

method read*(s: LPStream, n = -1): Future[seq[byte]]
  {.base, async.} =
  discard

method readExactly*(s: LPStream, pbytes: pointer, nbytes: int): Future[void]
  {.base, async.} =
  discard

method readLine*(s: LPStream, limit = 0, sep = "\r\n"): Future[string]
  {.base, async.} =
  discard

method readOnce*(s: LPStream, pbytes: pointer, nbytes: int): Future[int]
  {.base, async.} =
  discard

method readUntil*(s: LPStream,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): Future[int]
  {.base, async.} =
  discard

method write*(s: LPStream, pbytes: pointer, nbytes: int)
  {.base, async.} =
  discard

method write*(s: LPStream, msg: string, msglen = -1)
  {.base, async.} =
  discard

method write*(s: LPStream, msg: seq[byte], msglen = -1)
  {.base, async.} =
  discard

method close*(s: LPStream)
  {.base, async.} =
  discard
