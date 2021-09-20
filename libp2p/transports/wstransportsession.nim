import pkg/websock/websock
import pkg/chronicles
import ./session
import ./wsstream

export session

type
  WsTransportSession* = ref object of Session
    session: WsSession
    stream: WsStream

proc new*(_: type WsTransportSession,
          session: WsSession,
          dir: Direction): WsTransportSession =
  WsTransportSession(session: session, stream: WsStream.init(session, dir))

method getStream*(session: WsTransportSession): Future[Connection] {.async.} =
  result = session.stream

method close*(session: WsTransportSession) {.async.} =
  await session.stream.close()

method join*(session: WsTransportSession) {.async.} =
  await session.session.stream.reader.join()

func shortLog*(session: WsTransportSession): string =
  if session.isNil: "WsTransportSession(nil)"
  else: shortLog(session.stream)
chronicles.formatIt(WsTransportSession): shortLog(it)
