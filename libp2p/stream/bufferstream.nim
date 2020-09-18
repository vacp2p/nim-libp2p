## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements an asynchronous buffer stream
## which emulates physical async IO.
##
## The stream is based on the standard library's `Deque`,
## which is itself based on a ring buffer.
##
## It works by exposing a regular LPStream interface and
## a method ``pushTo`` to push data to the internal read
## buffer; as well as a handler that can be registered
## that gets triggered on every write to the stream. This
## allows using the buffered stream as a sort of proxy,
## which can be consumed as a regular LPStream but allows
## injecting data for reads and intercepting writes.
##
## Another notable feature is that the stream is fully
## ordered and asynchronous. Reads are queued up in order
## and are suspended when not enough data available. This
## allows preserving backpressure while maintaining full
## asynchrony. Both writing to the internal buffer with
## ``pushTo`` as well as reading with ``read*` methods,
## will suspend until either the amount of elements in the
## buffer goes below ``maxSize`` or more data becomes available.

import std/strformat
import stew/byteutils
import chronos, chronicles, metrics
import ../stream/connection
import ./streamseq

when chronicles.enabledLogLevel == LogLevel.TRACE:
  import oids

export connection

logScope:
  topics = "bufferstream"

const
  BufferStreamTrackerName* = "libp2p.bufferstream"

type
  BufferStreamTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupBufferStreamTracker(): BufferStreamTracker {.gcsafe.}

proc getBufferStreamTracker(): BufferStreamTracker {.gcsafe.} =
  result = cast[BufferStreamTracker](getTracker(BufferStreamTrackerName))
  if isNil(result):
    result = setupBufferStreamTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = "Opened buffers: " & $tracker.opened & "\n" &
           "Closed buffers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = (tracker.opened != tracker.closed)

proc setupBufferStreamTracker(): BufferStreamTracker =
  result = new BufferStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(BufferStreamTrackerName, result)

type
  BufferStream* = ref object of Connection
    readQueue*: AsyncQueue[seq[byte]] # read queue for managing backpressure
    readBuf*: StreamSeq               # overflow buffer for readOnce
    pushing*: int                     # number of ongoing push operations

    pushedEof*: bool

func shortLog*(s: BufferStream): auto =
  if s.isNil: "BufferStream(nil)"
  elif s.peerInfo.isNil: $s.oid
  else: &"{shortLog(s.peerInfo.peerId)}:{s.oid}"
chronicles.formatIt(BufferStream): shortLog(it)

proc len*(s: BufferStream): int =
  s.readBuf.len + (if s.readQueue.len > 0: s.readQueue[0].len() else: 0)

method initStream*(s: BufferStream) =
  if s.objName.len == 0:
    s.objName = "BufferStream"

  procCall Connection(s).initStream()

  s.readQueue = newAsyncQueue[seq[byte]](1)

  trace "BufferStream created", s
  inc getBufferStreamTracker().opened

proc newBufferStream*(timeout: Duration = DefaultConnectionTimeout): BufferStream =
  new result
  result.timeout = timeout
  result.initStream()

method pushData*(s: BufferStream, data: seq[byte]) {.base, async.} =
  ## Write bytes to internal read buffer, use this to fill up the
  ## buffer with data.
  ##
  ## `pushTo` will block if the queue is full, thus maintaining backpressure.
  ##
  if s.isClosed or s.pushedEof:
    raise newLPStreamEOFError()

  if data.len == 0:
    return # Don't push 0-length buffers, these signal EOF

  # We will block here if there is already data queued, until it has been
  # processed
  inc s.pushing
  try:
    trace "Pushing data", s, data = data.len
    await s.readQueue.addLast(data)
  finally:
    dec s.pushing

method pushEof*(s: BufferStream) {.base, async.} =
  if s.pushedEof:
    return
  s.pushedEof = true

  # We will block here if there is already data queued, until it has been
  # processed
  inc s.pushing
  try:
    trace "Pushing EOF", s
    await s.readQueue.addLast(@[])
  finally:
    dec s.pushing

method readOnce*(s: BufferStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  doAssert(nbytes > 0, "nbytes must be positive integer")
  if s.isEof and s.readBuf.len() == 0:
    raise newLPStreamEOFError()

  var
    p = cast[ptr UncheckedArray[byte]](pbytes)

  # First consume leftovers from previous read
  var rbytes = s.readBuf.consumeTo(toOpenArray(p, 0, nbytes - 1))

  if rbytes < nbytes:
    # There's space in the buffer - consume some data from the read queue
    trace "popping readQueue", s, rbytes, nbytes
    let buf = await s.readQueue.popFirst()

    if buf.len == 0 or s.isEof: # Another task might have set EOF!
      # No more data will arrive on read queue
      s.isEof = true
    else:
      let remaining = min(buf.len, nbytes - rbytes)
      toOpenArray(p, rbytes, nbytes - 1)[0..<remaining] =
        buf.toOpenArray(0, remaining - 1)
      rbytes += remaining

      if remaining < buf.len:
        trace "add leftovers", s, len = buf.len - remaining
        s.readBuf.add(buf.toOpenArray(remaining, buf.high))

  if s.isEof and s.readBuf.len() == 0:
    # We can clear the readBuf memory since it won't be used any more
    s.readBuf = StreamSeq()

  s.activity = true

  return rbytes

method closeImpl*(s: BufferStream): Future[void] =
  ## close the stream and clear the buffer
  trace "Closing BufferStream", s, len = s.len

  if not s.pushedEof: # Potentially wake up reader
    asyncSpawn s.pushEof()

  inc getBufferStreamTracker().closed
  trace "Closed BufferStream", s

  procCall Connection(s).closeImpl() # noraises, nocancels
