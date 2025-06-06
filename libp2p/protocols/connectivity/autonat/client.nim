# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import results
import chronos, chronicles
import ../../../switch, ../../../multiaddress, ../../../peerid
import core

logScope:
  topics = "libp2p autonat"

type AutonatClient* = ref object of RootObj

proc sendDial(
    conn: Connection, pid: PeerId, addrs: seq[MultiAddress]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let pb = AutonatDial(
    peerInfo: Opt.some(AutonatPeerInfo(id: Opt.some(pid), addrs: addrs))
  ).encode()
  await conn.writeLp(pb.buffer)

method dialMe*(
    self: AutonatClient,
    switch: Switch,
    pid: PeerId,
    addrs: seq[MultiAddress] = newSeq[MultiAddress](),
): Future[MultiAddress] {.
    base, async: (raises: [AutonatError, AutonatUnreachableError, CancelledError])
.} =
  proc getResponseOrRaise(
      autonatMsg: Opt[AutonatMsg]
  ): AutonatDialResponse {.raises: [AutonatError].} =
    autonatMsg.withValue(msg):
      if msg.msgType == DialResponse:
        msg.response.withValue(res):
          if not (res.status == Ok and res.ma.isNone()):
            return res
    raise newException(AutonatError, "Unexpected response")

  let conn =
    try:
      if addrs.len == 0:
        await switch.dial(pid, @[AutonatCodec])
      else:
        await switch.dial(pid, addrs, AutonatCodec)
    except CancelledError as err:
      raise err
    except DialFailedError as err:
      raise
        newException(AutonatError, "Unexpected error when dialling: " & err.msg, err)

  # To bypass maxConnectionsPerPeer
  let incomingConnection = switch.connManager.expectConnection(pid, In)
  if incomingConnection.failed() and
      incomingConnection.error of AlreadyExpectingConnectionError:
    raise newException(AutonatError, incomingConnection.error.msg)
  defer:
    await conn.close()
    incomingConnection.cancel()
      # Safer to always try to cancel cause we aren't sure if the peer dialled us or not
    if incomingConnection.completed():
      try:
        await (await incomingConnection).connection.close()
      except AlreadyExpectingConnectionError as e:
        # this err is already handled above and could not happen later
        error "Unexpected error", description = e.msg

  try:
    trace "sending Dial", addrs = switch.peerInfo.addrs
    await conn.sendDial(switch.peerInfo.peerId, switch.peerInfo.addrs)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise newException(AutonatError, "Sending dial failed", e)

  var respBytes: seq[byte]
  try:
    respBytes = await conn.readLp(1024)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    raise newException(AutonatError, "read Dial response failed: " & e.msg, e)

  let response = getResponseOrRaise(AutonatMsg.decode(respBytes))

  return
    case response.status
    of ResponseStatus.Ok:
      try:
        response.ma.tryGet()
      except ResultError[void]:
        raiseAssert("checked with if")
    of ResponseStatus.DialError:
      raise newException(
        AutonatUnreachableError, "Peer could not dial us back: " & response.text.get("")
      )
    else:
      raise newException(
        AutonatError, "Bad status " & $response.status & " " & response.text.get("")
      )
