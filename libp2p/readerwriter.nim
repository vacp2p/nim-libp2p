## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

type ReadWrite* = ref object of RootObj

method read*(s: ReadWrite, n = -1): Future[seq[byte]] 
  {.base, async.} =
  discard

method readExactly*(s: ReadWrite, pbytes: pointer, nbytes: int): Future[void] 
  {.base, async.} =
  discard

method readLine*(s: ReadWrite, limit = 0, sep = "\r\n"): Future[string] 
  {.base, async.} = 
  discard

method readOnce*(s: ReadWrite, pbytes: pointer, nbytes: int): Future[int] 
  {.base, async.} = 
  discard

method readUntil*(s: ReadWrite, pbytes: pointer, nbytes: int, sep: seq[byte]): Future[int] 
  {.base, async.} = 
  discard

method write*(w: ReadWrite, pbytes: pointer, nbytes: int)
  {.base, async.} = 
  discard

method write*(w: ReadWrite, msg: string, msglen = -1)
  {.base, async.} = 
  discard

method write*(w: ReadWrite, msg: seq[byte], msglen = -1)
  {.base, async.} = 
  discard

method close*(w: ReadWrite) 
  {.base, async.} = 
  discard
