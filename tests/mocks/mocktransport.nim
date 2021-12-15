{.push raises: [Defect].}

import chronos
import ../../libp2p/[multiaddress,
       stream/connection,
       transports/transport,
       upgrademngrs/upgrade]
import ./mockconnection,
       ../helpers

type
  StartMock* = proc(self: MockTransport, addrs: seq[MultiAddress]): Future[void] {.gcsafe.}

  StopMock* = proc(self: MockTransport): Future[void] {.gcsafe.}

  AcceptMock* = proc(self: MockTransport): Future[Connection] {.gcsafe.}

  MockTransport* = ref object of Transport
    startMock*: StartMock
    stopMock*: StopMock
    acceptMock*: AcceptMock

const StartMockDefault =
  proc(self: MockTransport, addrs: seq[MultiAddress]) {.async.} =
    discard

const StopMockDefault =
  proc(self: MockTransport) {.async.} =
    discard

const AcceptMockDefault =
  proc(self: MockTransport): Future[Connection] =
    let
      fut = newFuture[Connection]("mocktransport.accept.future")
      peerId = PeerID.init(PrivateKey.random(ECDSA, rng[]).get()).get()
      conn = MockConnection.new(peerId)
    fut.complete(conn)
    return fut

proc new*(
  T: typedesc[MockTransport],
  upgrader: Upgrade,
  acceptMock: AcceptMock = AcceptMockDefault,
  startMock: StartMock = StartMockDefault,
  stopMock: StopMock = StopMockDefault,
  listenError: ListenErrorCallback = ListenErrorDefault): T =

  let transport = T(
    upgrader: upgrader,
    startMock: startMock,
    stopMock: stopMock,
    acceptMock: acceptMock,
    listenError: listenError)

  # if transport.listenError.isNil:
  #   transport.listenError = ListenErrorDefault

  return transport

method start*(self: MockTransport, addrs: seq[MultiAddress]) {.async, raises: [Defect, TransportListenError].} =
  self.addrs = addrs
  await self.startMock(self, addrs)
  self.running = true

method stop*(self: MockTransport) {.async, gcsafe.} =
  await self.stopMock(self)
  self.running = false

method accept*(self: MockTransport): Future[Connection] {.async, gcsafe.} =
  return await self.acceptMock(self)
