# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/options
import stew/results
import chronos, chronicles
import ../../../switch,
       ../../../multiaddress,
       ../../../peerid
import core

logScope:
  topics = "libp2p autonat"

type
  AutonatClient* = ref object of RootObj

proc sendDial(conn: Connection, pid: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let pb = AutonatDial(peerInfo: Opt.some(AutonatPeerInfo(
                         id: Opt.some(pid),
                         addrs: addrs
                       ))).encode()
  await conn.writeLp(pb.buffer)

method dialMe*(self: AutonatClient, switch: Switch, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.base, async.} =

  proc getResponseOrRaise(autonatMsg: Opt[AutonatMsg]): AutonatDialResponse {.raises: [AutonatError].} =
    let
      msg = autonatMsg.valueOr: raise newException(AutonatError, "Unexpected response")
      res = msg.response.valueOr: raise newException(AutonatError, "Unexpected response")

    if msg.msgType != DialResponse or (res.status == Ok and res.ma.isNone()):
       raise newException(AutonatError, "Unexpected response")
    else:
      res

  let conn =
    try:
      if addrs.len == 0:
        await switch.dial(pid, @[AutonatCodec])
      else:
        await switch.dial(pid, addrs, AutonatCodec)
    except CatchableError as err:
      raise newException(AutonatError, "Unexpected error when dialling: " & err.msg, err)

  # To bypass maxConnectionsPerPeer
  let incomingConnection = switch.connManager.expectConnection(pid, In)
  if incomingConnection.failed() and incomingConnection.error of AlreadyExpectingConnectionError:
    raise newException(AutonatError, incomingConnection.error.msg)
  defer:
    await conn.close()
    incomingConnection.cancel() # Safer to always try to cancel cause we aren't sure if the peer dialled us or not
    if incomingConnection.completed():
      await (await incomingConnection).connection.close()
  trace "sending Dial", addrs = switch.peerInfo.addrs
  await conn.sendDial(switch.peerInfo.peerId, switch.peerInfo.addrs)
  let response = getResponseOrRaise(AutonatMsg.decode(await conn.readLp(1024)))
  return case response.status:
    of ResponseStatus.Ok:
      response.ma.tryGet()
    of ResponseStatus.DialError:
      raise newException(AutonatUnreachableError, "Peer could not dial us back: " & response.text.get(""))
    else:
      raise newException(AutonatError, "Bad status " & $response.status & " " & response.text.get(""))
