# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos

import ../../../stream/connection

type RelayConnection* = ref object of Connection
  stream*: Stream
  limitDuration*: uint32
  limitData*: uint64
  dataSent*: uint64
  durationCheckFut: Future[void]

method readOnce*(
    self: RelayConnection, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  self.activity = true
  self.stream.readOnce(pbytes, nbytes)

method write*(
    self: RelayConnection, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  let msgLen = msg.len
  self.dataSent.inc(msgLen)
  if self.limitData != 0 and self.dataSent > self.limitData:
    await self.close()
    return
  self.activity = true
  await self.stream.write(move(msg))

method closeImpl*(self: RelayConnection): Future[void] {.async: (raises: []).} =
  if not self.durationCheckFut.isNil:
    self.durationCheckFut.cancelSoon()
  await self.stream.close()
  await procCall Connection(self).closeImpl()

method resetImpl*(self: RelayConnection): Future[void] {.async: (raises: []).} =
  if not self.durationCheckFut.isNil:
    self.durationCheckFut.cancelSoon()
  await self.stream.reset()
  await procCall Connection(self).closeImpl()

method getWrapped*(self: RelayConnection): Connection =
  self.stream

proc new*(
    T: typedesc[RelayConnection],
    stream: Stream,
    limitDuration: uint32,
    limitData: uint64,
): T =
  let rc = T(stream: stream, limitDuration: limitDuration, limitData: limitData)
  rc.dir = stream.dir
  rc.initStream()
  if limitDuration > 0:
    proc checkDurationConnection() {.async: (raises: []).} =
      try:
        await stream.join().wait(limitDuration.seconds())
      except AsyncTimeoutError:
        await stream.close()
      except CancelledError:
        discard

    rc.durationCheckFut = checkDurationConnection()
  return rc
