## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, peerinfo, multiaddress

const DefaultReadSize = 1024

type
  Connection* = ref object of RootObj
    reader: AsyncStreamReader
    writter: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport

proc newConnection*(server: StreamServer,
                    client: StreamTransport): Connection = 
  ## create a new Connection for the specified async stream reader/writter
  new result
  result.server = server
  result.client = client

  result.reader = newAsyncStreamReader(client)
  result.writter = newAsyncStreamWriter(client)

method read* (c: Connection, size: int = DefaultReadSize): Future[seq[byte]] {.base, async, gcsafe.} = 
  ## read DefaultReadSize (1024) bytes or `size` bytes if specified
  result = await c.reader.read(size)

method write* (c: Connection, data: pointer, size: int): Future[void] {.base, async.} = 
  ## write bytes pointed to by `data` up to `size` size
  discard c.writter.write(data, size)

method close* (c: Connection): Future[void] {.base, async.} = 
  ## close connection
  ## TODO: figure out how to correctly close the streams and underlying resource
  discard

method getPeerInfo* (c: Connection): Future[PeerInfo] {.base, async.} = 
  ## get up to date peer info
  ## TODO: implement PeerInfo refresh over identify
  discard

method getObservedAddrs(c: Connection): Future[seq[MultiAddress]] {.base, async.} =
  ## get resolved multiaddresses for the connection
  discard
