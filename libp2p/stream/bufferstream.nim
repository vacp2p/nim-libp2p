## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

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
  BufferStreamTrackerName* = "BufferStream"

type
  BufferStream* = ref object of Connection
    readQueue*: AsyncQueue[seq[byte]] # read queue for managing backpressure
    readBuf*: StreamSeq               # overflow buffer for readOnce
    pushing*: int                     # number of ongoing push operations
    reading*: bool                    # is there an ongoing read? (only allow one)
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
  doAssert(not s.reading, "Only one concurrent read allowed")

  if s.isEof and s.readBuf.len() == 0:
    raise newLPStreamEOFError()

  var
    p = cast[ptr UncheckedArray[byte]](pbytes)

  # First consume leftovers from previous read
  var rbytes = s.readBuf.consumeTo(toOpenArray(p, 0, nbytes - 1))

  if rbytes < nbytes:
    # There's space in the buffer - consume some data from the read queue
    s.reading = true
    let buf =
      try:
        await s.readQueue.popFirst()
      finally:
        s.reading = false

    if buf.len == 0:
      # No more data will arrive on read queue
      trace "EOF", s
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

  trace "Closed BufferStream", s

  procCall Connection(s).closeImpl() # noraises, nocancels
