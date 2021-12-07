{.push raises: [Defect].}

import chronos
import transport,
       ../multiaddress,
       ../stream/connection

type
  StartMock* = proc(addrs: seq[MultiAddress]): Future[void] {.gcsafe.}

  StopMock* = proc(): Future[void] {.gcsafe.}

  AcceptMock* = proc(): Future[Connection] {.gcsafe.}

  MockTransport* = ref object of Transport
    startMoc*: StartMock
    stopMoc*: StopMock
    acceptMoc*: AcceptMock

const STARTMOCK_DEFAULT =
  proc(addrs: seq[MultiAddress]) {.async.} =
    discard

const STOPMOCK_DEFAULT =
  proc() {.async.} =
    discard

const ACCEPTMOCK_DEFAULT =
  proc(): Future[Connection] =
    let
      fut = newFuture[Connection]("mocktransport.accept.future")
      conn = Connection()
    fut.complete(conn)
    return fut

proc new*(
  T: typedesc[MockTransport],
  startMock: StartMock = STARTMOCK_DEFAULT,
  stopMock: StopMock = STOPMOCK_DEFAULT,
  acceptMock: AcceptMock = ACCEPTMOCK_DEFAULT): T =

  let transport = T(
    startMoc: startMock,
    stopMoc: stopMock,
    acceptMoc: acceptMock)

  return transport

method start*(self: MockTransport, addrs: seq[MultiAddress]) {.async.} =
  self.addrs = addrs
  await self.startMoc(addrs)
  self.running = true

method stop*(self: MockTransport) {.async, gcsafe.} =
  await self.stopMoc()
  self.running = false

method accept*(self: MockTransport): Future[Connection] {.async, gcsafe.} =
  return await self.acceptMoc()
