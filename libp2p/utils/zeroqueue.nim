type ZeroQueue* = object
  data: seq[seq[byte]] = @[]

proc clear*(q: var ZeroQueue) =
  q.data = @[]

proc isEmpty*(q: ZeroQueue): bool =
  return q.data.len == 0

proc len*(q: ZeroQueue): int64 =
  var l: int64
  for b in q.data:
    l += b.len
  return l

proc push*(q: var ZeroQueue, b: seq[byte]) =
  if b.len > 0:
    q.data.add(b)

proc pop*(q: var ZeroQueue, count: int): seq[byte] =
  if q.data.len == 0 or count == 0:
    return @[]

  let first = q.data[0]
  if first.len <= count:
    q.data = q.data[1 ..^ 1]
    return first
  else:
    let ret = first[0 ..< count]
    q.data[0] = first[count ..^ 1]
    return ret

proc consumeTo*(q: var ZeroQueue, pbytes: pointer, nbytes: int): int =
  var consumed = 0
  while consumed < nbytes and not q.isEmpty():
    let data = q.pop(nbytes - consumed)
    let dest = cast[pointer](cast[ByteAddress](pbytes) + consumed)
    copyMem(dest, unsafeAddr data[0], data.len)
    consumed += data.len

  return consumed
