## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

## This module implements Pool of StreamTransport.
import chronos

const
  DefaultPoolSize* = 8
    ## Default pool size

type
  ConnectionFlags = enum
    None, Busy

  PoolItem = object
    transp*: StreamTransport
    flags*: set[ConnectionFlags]

  PoolState = enum
    Connecting, Connected, Closing, Closed

  TransportPool* = ref object
    ## Transports pool object
    transports: seq[PoolItem]
    busyCount: int
    state: PoolState
    bufferSize: int
    event: AsyncEvent

  TransportPoolError* = object of AsyncError

proc waitAll[T](futs: seq[Future[T]]): Future[void] =
  ## Performs waiting for all Future[T].
  var counter = len(futs)
  var retFuture = newFuture[void]("connpool.waitAllConnections")
  proc cb(udata: pointer) =
    dec(counter)
    if counter == 0:
      retFuture.complete()
  for fut in futs:
    fut.addCallback(cb)
  return retFuture

proc newPool*(address: TransportAddress, poolsize: int = DefaultPoolSize,
              bufferSize = DefaultStreamBufferSize,
             ): Future[TransportPool] {.async.} =
  ## Establish pool of connections to address ``address`` with size
  ## ``poolsize``.
  var pool = new TransportPool
  pool.bufferSize = bufferSize
  pool.transports = newSeq[PoolItem](poolsize)
  var conns = newSeq[Future[StreamTransport]](poolsize)
  pool.state = Connecting
  for i in 0..<poolsize:
    conns[i] = connect(address, bufferSize)
  # Waiting for all connections to be established.
  await waitAll(conns)
  # Checking connections and preparing pool.
  for i in 0..<poolsize:
    if conns[i].failed:
      raise conns[i].error
    else:
      let transp = conns[i].read()
      let item = PoolItem(transp: transp)
      pool.transports[i] = item
  # Setup available connections event
  pool.event = newAsyncEvent()
  pool.state = Connected
  result = pool

proc acquire*(pool: TransportPool): Future[StreamTransport] {.async.} =
  ## Acquire non-busy connection from pool ``pool``.
  var transp: StreamTransport
  if pool.state in {Connected}:
    while true:
      if pool.busyCount < len(pool.transports):
        for conn in pool.transports.mitems():
          if Busy notin conn.flags:
            conn.flags.incl(Busy)
            inc(pool.busyCount)
            transp = conn.transp
            break
      else:
        await pool.event.wait()
        pool.event.clear()

      if not isNil(transp):
        break
  else:
    raise newException(TransportPoolError, "Pool is not ready!")
  result = transp

proc release*(pool: TransportPool, transp: StreamTransport) =
  ## Release connection ``transp`` back to pool ``pool``.
  if pool.state in {Connected, Closing}:
    var found = false
    for conn in pool.transports.mitems():
      if conn.transp == transp:
        conn.flags.excl(Busy)
        dec(pool.busyCount)
        pool.event.fire()
        found = true
        break
    if not found:
      raise newException(TransportPoolError, "Transport not bound to pool!")
  else:
    raise newException(TransportPoolError, "Pool is not ready!")

proc join*(pool: TransportPool) {.async.} =
  ## Waiting for all connection to become available.
  if pool.state in {Connected, Closing}:
    while true:
      if pool.busyCount == 0:
        break
      else:
        await pool.event.wait()
        pool.event.clear()
  elif pool.state == Connecting:
    raise newException(TransportPoolError, "Pool is not ready!")

proc close*(pool: TransportPool) {.async.} =
  ## Closes transports pool ``pool`` and release all resources.
  if pool.state == Connected:
    pool.state = Closing
    # Waiting for all transports to become available.
    await pool.join()
    # Closing all transports
    var pending = newSeq[Future[void]](len(pool.transports))
    for i in 0..<len(pool.transports):
      let transp = pool.transports[i].transp
      transp.close()
      pending[i] = transp.join()
    # Waiting for all transports to be closed
    await waitAll(pending)
    # Mark pool as `Closed`.
    pool.state = Closed
