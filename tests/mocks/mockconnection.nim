## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[hashes, oids, strformat]
import chronicles, chronos, metrics
import ../../libp2p/[multiaddress,
       stream/connection,
       stream/lpstream,
       peerinfo,
       errors]
import ../helpers

export lpstream, peerinfo, errors

logScope:
  topics = "libp2p connection"

type
  ReadOnceMock* = proc(self: MockConnection, pbytes: pointer, nbytes: int): Future[int] {.gcsafe.}
  WriteMock* = proc(self: MockConnection, msg: seq[byte]): Future[void] {.gcsafe.}

  MockConnection* = ref object of Connection
    readOnceMock*: ReadOnceMock
    writeMock*: WriteMock

const ReadOnceMockDefault =
  proc(self: MockConnection, pbytes: pointer, nbytes: int): Future[int] {.async.} =
    discard

const WriteMockDefault =
  proc(self: MockConnection, msg: seq[byte]) {.async.} =
    discard

method readOnce*(
    self: MockConnection,
    pbytes: pointer,
    nbytes: int):
    Future[int] {.async.} =

  return await self.readOnceMock(self, pbytes, nbytes)

method write*(self: MockConnection, msg: seq[byte]): Future[void] {.async.} =
  await self.writeMock(self, msg)

proc new*(C: typedesc[MockConnection],
    peerId: PeerId,
    dir: Direction = Direction.In,
    timeout: Duration = DefaultConnectionTimeout,
    timeoutHandler: TimeoutHandler = nil,
    observedAddr: MultiAddress = MultiAddress(),
    readOnceMock: ReadOnceMock = ReadOnceMockDefault,
    writeMock: WriteMock = WriteMockDefault): MockConnection =

  let conn = C(peerId: peerId,
      dir: dir,
      timeout: timeout,
      timeoutHandler: timeoutHandler,
      observedAddr: observedAddr,
      readOnceMock: readOnceMock,
      writeMock: writeMock)


  conn.initStream()
  return conn
