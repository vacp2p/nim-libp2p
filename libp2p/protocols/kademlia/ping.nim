# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[protobuf, types]

proc ping*(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]
): Future[bool] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let conn = await kad.switch.dial(peerId, addrs, KadCodec)
  defer:
    await conn.close()

  let request = Message(msgType: MessageType.ping)
  await conn.writeLp(request.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).tryGet()

  reply == request

proc handlePing*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  try:
    await conn.writeLp(msg.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send ping reply", conn = conn, err = exc.msg
    return
