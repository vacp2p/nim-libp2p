import chronos, chronicles
import stream, ringbuffer

const
  DefaultBuffSize* = 1 shl 20

type
  Reader*[T: byte | char] = ref object of Stream[T]
    readBuff: RingBuffer[T]
    source: Source[T]

proc init*[T](R: type(Reader[T]),
              source: Source[T] | Stream[T],
              maxSize: int = DefaultBuffSize): R =
  R(source: source, readBuff: RingBuffer[T].init(maxSize))

proc read*[T](r: Reader[T],
              n = -1): Future[seq[T]] {.async.} =
  var size = n
  if size < 0:
    size = r.len

  result = newSeq[T](size)
  var pos = 0
  for msg in r.source:
    var chunk = await msg
    r.readBuffer.append(chunk)

    if r.readBuffer.len >= size:
      r.readBuffer.read(result)
      size = 0
      break
    else:
      var last = pos + size - 1
      if last <= 0:
        last = 1

      var read = r.readBuff.read(result.toOpenArray(pos, last))
      size -= read
      pos += read

      if size <= 0:
        trace "LENPREF RESULT ", result = result
        break

proc rest*[T](r: Reader): Source[T] =
  return iterator(): Future[T] =
    if r.readBuff.len > 0:
      yield r.read()

    for i in r.source():
      yield i
