# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, sets, sequtils]
import stew/[results, objects]
import chronos, chronicles
import ../../../switch,
       ../../../multiaddress,
       ../../../peerid
import core

export core

logScope:
  topics = "libp2p autonat"

type
  AutonatClient* = ref object of RootObj

proc sendDial(conn: Connection, pid: PeerId, addrs: seq[MultiAddress]) {.async.} =
  let pb = AutonatDial(peerInfo: some(AutonatPeerInfo(
                         id: some(pid),
                         addrs: addrs
                       ))).encode()
  await conn.writeLp(pb.buffer)

method dialMe*(self: AutonatClient, switch: Switch, pid: PeerId, addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.base, async.} =

  proc getResponseOrRaise(autonatMsg: Option[AutonatMsg]): AutonatDialResponse {.raises: [UnpackError, AutonatError].} =
    if autonatMsg.isNone() or
       autonatMsg.get().msgType != DialResponse or
       autonatMsg.get().response.isNone() or
       (autonatMsg.get().response.get().status == Ok and
        autonatMsg.get().response.get().ma.isNone()):
      raise newException(AutonatError, "Unexpected response")
    else:
      autonatMsg.get().response.get()

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
      await (await incomingConnection).close()
  trace "sending Dial", addrs = switch.peerInfo.addrs
  await conn.sendDial(switch.peerInfo.peerId, switch.peerInfo.addrs)
  let response = getResponseOrRaise(AutonatMsg.decode(await conn.readLp(1024)))
  return case response.status:
    of ResponseStatus.Ok:
      response.ma.get()
    of ResponseStatus.DialError:
      raise newException(AutonatUnreachableError, "Peer could not dial us back: " & response.text.get(""))
    else:
      raise newException(AutonatError, "Bad status " & $response.status & " " & response.text.get(""))
