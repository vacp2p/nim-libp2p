## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import typetraits
import chronos
import chronicles
import ../protocol,
       ../../connection,
       ../../stream/bufferstream

logScope:
  topic = "secure"

type
  Secure* = ref object of LPProtocol # base type for secure managers
  SecureConnection* = ref object of Connection

proc readLoop*[T: SecureConnection](sconn: T, stream: BufferStream) {.async.} =
  const tname = typedesc[T].name
  try:
    while not sconn.closed:
      let msg = await sconn.readMessage()
      if msg.len == 0:
        trace "stream EOF"
        return

      await stream.pushTo(msg)
  except CatchableError as exc:
    trace "exception occurred " & tname & ".readLoop", exc = exc.msg
  finally:
    if not sconn.closed:
      await sconn.close()
    const msg = "ending " & tname & ".readLoop"
    trace msg, isclosed = sconn.closed()

method secure*(p: Secure, conn: Connection, outgoing: bool): Future[Connection]
  {.base, async, gcsafe.} =
  ## default implementation matches plaintext
  result = conn
