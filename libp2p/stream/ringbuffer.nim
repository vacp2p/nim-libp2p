type
  RingBuffer*[T: byte | char] = object
    buff: seq[T]
    head, tail, size, len: int

const DefaultSize = 1024

## A bare bones ring buffer suited for byte oriented data.
## The buffer uses `shallowCopy` when appending and reading
## data to overcome Nim's copy semantics.
##
## This is a FIFO data structure, data is always appended to the end
## and read from the front.
##

proc init*[T](b: type[RingBuffer[T]], size = DefaultSize): b =
  ## Create and initialize the ring buffer. Takes an optional
  ## maximum ``size`` parameter, otherwise ``size`` will default
  ## to ``DefaultSize`` which is set to 1024.
  ##
  ## .. code-block:: nim
  ##   # create a buffer with 5
  ##   var buff = RingBuffer[byte].init(5)
  ##   buff.add(@['a', 'b', 'c', 'd', 'e'])
  ##   var data = newSeq[char](5)
  ##   discard buff.read(data)
  ##   echo data # prints @['a', 'b', 'c', 'd', 'e']
  ##
  RingBuffer[T](buff: newSeq[T](size), size: size)

proc append*[T](b: var RingBuffer[T], data: openArray[T]) =
  ## Append data to the end of the buffer. ``data`` will be
  ## ``shallowCopy``ed into the buffer to overcome Nim's copy
  ## semantics for ``seq``.
  ##
  ## .. code-block:: nim
  ##    buff.append(@['a', 'b', 'b', 'c', 'd'])
  ##
  if data.len + b.len > b.size:
    raise newException(CatchableError, "Buffer would overflow!")

  for i in data:
    shallowCopy(b.buff[b.tail], i)
    if b.tail == b.size - 1:
      b.tail = 0
    else:
      b.tail.inc
    b.len.inc

proc read*[T](b: var RingBuffer[T],
              data: var openArray[T],
              size: int = -1): int =
  ## Read up to ``size`` bytes/chars from the front of the buffer
  ## into the ``data`` argument.
  ##
  ## Returns an int indicating the amount of bytes/chars read.
  ##
  ## Note that ``size`` is the maximum amount of bytes/chars to
  ## read, if not enough data is available read will return what
  ## it can. If ``size`` is not provided, then the ``len`` field
  ## of the ``data`` argument will be used instead.
  ##
  ## .. code-block:: nim
  ## # read 5 chars from the buffer
  ## var data = newSeq[char](10)
  ## assert(buff.read(data, 5) == 5)
  ##
  if b.len == 0:
    return

  if data.len == 0 or size > data.len:
    raise newException(CatchableError, "Data isn't big enough!")

  var isize = size
  if size > b.size:
    isize = b.size

  if size < 0 or size > b.len:
    isize = b.len
  else:
    isize = size

  while result < isize:
    shallowCopy(data[result], b.buff[b.head])
    if b.len == 0:
      break

    if b.head == b.size - 1:
      b.head = 0
    else:
      b.head.inc()
    b.len.dec
    result.inc

proc read*[T](b: var RingBuffer[T], size: int = -1): seq[T] =
  ## Read up to ``size`` bytes/chars from the front of the buffer.
  ##
  ## Returns a `seq` with the read bytes/chars.
  ##
  ## Note that ``size`` is the maximum amount of bytes/chars to read,
  ## if not enough data is available read will return what it can.
  ## If ``size`` is not provided, the entire contents of the buffer
  ## will be returned.
  ##
  ## .. code-block:: nim
  ## # read 5 chars from the buffer
  ## assert(buff.read() == @[...])
  ##
  var isize = size
  if size < 0 or size > b.len:
    isize = b.len

  result = newSeq[T](isize)
  discard b.read(result, isize)

proc reset*[T](b: var RingBuffer[T]) =
  ## Reset the internal state of the buffer. The
  ## internal buffer itself will not be cleared,
  ## but all internal pointers will be which allows
  ## reusing the buffer as if new.
  b.len = 0
  b.head = 0
  b.tail = 0

proc clear*[T](b: var RingBuffer[T]) =
  ## Reset and clear the buffer.
  b.reset()
  b.buff.setLen(0)

when isMainModule:

  block:
    ## Basic tests
    var buff = RingBuffer[char].init(10)
    var data = newSeq[char](10)

    buff.append(@['a', 'b', 'c', 'd', 'e'])
    assert(buff.len == 5, "len should be 5")
    assert(buff.head == 0, "head should be 0")
    assert(buff.tail == 5, "tail should b4 5")

    buff.append(@['f', 'g', 'h', 'i', 'j'])
    assert(buff.len == 10, "len should be 10")
    assert(buff.head == 0, "head should be 0")
    assert(buff.tail == 0, "tail should be 0")

    assert(buff.read(data, 5) == 5, "should have read 5 chars")
    assert(data[0..4] == @['a', 'b', 'c', 'd', 'e'])
    assert(buff.len == 5, "len should be 5")
    assert(buff.head == 5, "head should be 5")
    assert(buff.tail == 0, "tail should be 0")

    buff.append(@['k', 'l', 'm', 'n', 'o'])
    assert(buff.len == 10, "len should be 10")
    assert(buff.head == 5, "head should be 5")
    assert(buff.tail == 5, "tail should be 5")

    assert(buff.read(data, 2) == 2, "should have read 2 chars")
    assert(data[0..1] == @['f', 'g'])
    assert(buff.len == 8, "len should be 8")
    assert(buff.head == 7, "head should be 7")
    assert(buff.tail == 5, "tail should be 5")

    buff.append(@['p', 'q'])
    assert(buff.len == 10, "len should be 10")
    assert(buff.head == 7, "head should be 7")
    assert(buff.tail == 7, "tail should be 7")

    assert(buff.read(data) == 10, "should have read 10 chars")
    assert(data == @['h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q'])
    assert(buff.len == 0, "len should be 0")
    assert(buff.head == 7, "head should be 7")
    assert(buff.tail == 7, "tail should be 7")

    buff.append(@['x', 'y'])
    assert(buff.len == 2, "len should be 2")
    assert(buff.head == 7, "head should be 7")
    assert(buff.tail == 9, "tail should be 9")

    assert(buff.read(data, 4) == 2, "should have read 2 chars")
    assert(data[0..1] == @['x', 'y'])
    assert(buff.len == 0, "len should be 0")
    assert(buff.head == 9, "head should be 9")
    assert(buff.tail == 9, "tail should be 9")

    buff.append(@['a', 'b', 'c', 'd', 'e'])
    assert(buff.len == 5, "len should be 5")
    assert(buff.head == 9, "head should be 7")
    assert(buff.tail == 4, "tail should be 9")

    assert(buff.read(5) == @['a', 'b', 'c', 'd', 'e'])
    assert(buff.len == 0, "len should be 0")
    assert(buff.head == 4, "head should be 9")
    assert(buff.tail == 4, "tail should be 9")

  block:
    ## Try reading more than buff contents
    var buff = RingBuffer[char].init(10)
    var data = newSeq[char](10)

    buff.append(@['a'])
    assert(buff.len == 1, "len should be 1")
    assert(buff.head == 0, "head should be 0")
    assert(buff.tail == 1, "tail should be 1")

    assert(buff.read(5) == @['a'])
    assert(buff.len == 0, "len should be 0")
    assert(buff.head == 1, "head should be 9")
    assert(buff.tail == 1, "tail should be 9")

  block:
    ## Read one by one
    var buff = RingBuffer[char].init(10)

    var contents = @['a', 'b', 'c', 'd', 'e']
    buff.append(contents)
    for i in 0..<buff.len:
      assert(buff.read(1) == @[contents[i]])
      assert(buff.len == 4 - i)
      assert(buff.head == i + 1)
      assert(buff.tail == 5)

  block:
    ## Error checking
    var buff = RingBuffer[char].init(5)

    try:
      buff.append(@['a', 'b', 'c', 'd', 'e', 'g'])
      assert(false, "should not allow adding pas buffer size")
    except CatchableError as exc:
      assert(true)

    try:
      buff.append(@['a', 'b', 'c', 'd', 'e', 'g'])
      var data: seq[char]
      discard buff.read(data)
      assert(false, "should not allow passing empty container")
    except CatchableError as exc:
      assert(true)

    try:
      buff.append(@['a', 'b', 'c', 'd', 'e', 'g'])
      var data = newSeq[char](2)
      discard buff.read(data, 5)
      assert(false, "should not allow passing size greater than container")
    except CatchableError as exc:
      assert(true)

  block:
    ## Cleanup
    var buff = RingBuffer[char].init(5)

    buff.reset()
    assert(buff.len == 0, "buff.len should be 0")
    assert(buff.head == 0, "buff.head should be 0")
    assert(buff.tail == 0, "buff.tail should be 0")

    buff.clear()
    assert(buff.buff.len == 0, "buff.buff.len should be 0")

  echo "All passed!"
