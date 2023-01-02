# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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

import chronos

import ../../../stream/connection

type
  RelayConnection* = ref object of Connection
    conn*: Connection
    limitDuration*: uint32
    limitData*: uint64
    dataSent*: uint64

method readOnce*(
    self: RelayConnection,
    pbytes: pointer,
    nbytes: int): Future[int] {.async.} =
  self.activity = true
  return await self.conn.readOnce(pbytes, nbytes)

method write*(self: RelayConnection, msg: seq[byte]): Future[void] {.async.} =
  self.dataSent.inc(msg.len)
  if self.limitData != 0 and self.dataSent > self.limitData:
    await self.close()
    return
  self.activity = true
  await self.conn.write(msg)

method closeImpl*(self: RelayConnection): Future[void] {.async.} =
  await self.conn.close()
  await procCall Connection(self).closeImpl()

method getWrapped*(self: RelayConnection): Connection = self.conn

proc new*(
  T: typedesc[RelayConnection],
  conn: Connection,
  limitDuration: uint32,
  limitData: uint64): T =
  let rc = T(conn: conn, limitDuration: limitDuration, limitData: limitData)
  rc.initStream()
  if limitDuration > 0:
    proc checkDurationConnection() {.async.} =
      let sleep = sleepAsync(limitDuration.seconds())
      await sleep or conn.join()
      if sleep.finished: await conn.close()
      else: sleep.cancel()
    asyncSpawn checkDurationConnection()
  return rc
