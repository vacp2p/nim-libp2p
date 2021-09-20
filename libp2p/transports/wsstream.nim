import pkg/websock/websock
import ../multiaddress
import ../stream/connection

type
  WsStream* = ref object of Connection
    session*: WSSession

proc init*(T: type WsStream,
           session: WSSession,
           dir: Direction,
           timeout = 10.minutes,
           observedAddr: MultiAddress = MultiAddress()): T =

  let stream = T(
    session: session,
    timeout: timeout,
    dir: dir,
    observedAddr: observedAddr)

  stream.initStream()
  return stream

method readOnce*(
  s: WsStream,
  pbytes: pointer,
  nbytes: int): Future[int] {.async.} =
  let res = await s.session.recv(pbytes, nbytes)
  if res == 0 and s.session.readyState == ReadyState.Closed:
    raise newLPStreamEOFError()
  return res

method write*(
  s: WsStream,
  msg: seq[byte]): Future[void] {.async.} =
  try:
    await s.session.send(msg, Opcode.Binary)
  except WSClosedError:
    raise newLPStreamEOFError()

method closeImpl*(s: WsStream): Future[void] {.async.} =
  await s.session.close()
  await procCall Connection(s).closeImpl()
