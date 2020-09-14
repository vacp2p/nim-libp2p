import unittest
import chronos, stew/byteutils
import ../libp2p/stream/bufferstream,
       ../libp2p/stream/lpstream

{.used.}

suite "BufferStream":
  teardown:
    # echo getTracker("libp2p.bufferstream").dump()
    check getTracker("libp2p.bufferstream").isLeaked() == false

  test "push data to buffer":
    proc testPushTo(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0
      var data = "12345"
      await buff.pushTo(data.toBytes())
      check buff.len == 5
      result = true

      await buff.close()

    check:
      waitFor(testPushTo()) == true

  test "push and wait":
    proc testPushTo(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      let fut0 = buff.pushTo("1234".toBytes())
      let fut1 = buff.pushTo("5".toBytes())
      check buff.len == 4 # the second write should not be visible yet

      var data: array[1, byte]
      check: 1 == await buff.readOnce(addr data[0], data.len)

      check ['1'] == string.fromBytes(data)
      await fut0
      await fut1
      check buff.len == 4

      result = true

      await buff.close()

    check:
      waitFor(testPushTo()) == true

  test "read with size":
    proc testRead(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      await buff.pushTo("12345".toBytes())
      var data: array[3, byte]
      await buff.readExactly(addr data[0], data.len)
      check ['1', '2', '3'] == string.fromBytes(data)

      result = true

      await buff.close()

    check:
      waitFor(testRead()) == true

  test "readExactly":
    proc testReadExactly(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      await buff.pushTo("12345".toBytes())
      check buff.len == 5
      var data: array[2, byte]
      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == ['1', '2']

      result = true

      await buff.close()

    check:
      waitFor(testReadExactly()) == true

  test "readExactly raises":
    proc testReadExactly(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      await buff.pushTo("123".toBytes())
      var data: array[5, byte]
      var readFut = buff.readExactly(addr data[0], data.len)
      await buff.close()

      try:
        await readFut
      except LPStreamIncompleteError:
        result = true

    check:
      waitFor(testReadExactly()) == true

  test "readOnce":
    proc testReadOnce(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      var data: array[3, byte]
      let readFut = buff.readOnce(addr data[0], data.len)
      await buff.pushTo("123".toBytes())
      check buff.len == 3

      check (await readFut) == 3
      check string.fromBytes(data) == ['1', '2', '3']

      result = true

      await buff.close()

    check:
      waitFor(testReadOnce()) == true

  test "reads should happen in order":
    proc testWritePtr(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      let w1 = buff.pushTo("Msg 1".toBytes())
      let w2 = buff.pushTo("Msg 2".toBytes())
      let w3 = buff.pushTo("Msg 3".toBytes())

      var data: array[5, byte]
      await buff.readExactly(addr data[0], data.len)

      check string.fromBytes(data) == "Msg 1"

      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == "Msg 2"

      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == "Msg 3"

      for f in [w1, w2, w3]: await f

      let w4 = buff.pushTo("Msg 4".toBytes())
      let w5 = buff.pushTo("Msg 5".toBytes())
      let w6 = buff.pushTo("Msg 6".toBytes())

      await buff.close()

      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == "Msg 4"

      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == "Msg 5"

      await buff.readExactly(addr data[0], data.len)
      check string.fromBytes(data) == "Msg 6"

      for f in [w4, w5, w6]: await f

      result = true

    check:
      waitFor(testWritePtr()) == true

  test "small reads":
    proc testWritePtr(): Future[bool] {.async.} =
      let buff = newBufferStream()
      check buff.len == 0

      var writes: seq[Future[void]]
      var str: string
      for i in 0..<10:
        writes.add buff.pushTo("123".toBytes())
        str &= "123"
      await buff.close() # all data should still be read after close

      var str2: string
      var data: array[2, byte]
      try:
        while true:
          let x = await buff.readOnce(addr data[0], data.len)
          str2 &= string.fromBytes(data[0..<x])
      except LPStreamEOFError:
        discard

      for f in writes: await f

      check str == str2

      result = true

      await buff.close()

    check:
      waitFor(testWritePtr()) == true

  test "shouldn't get stuck on close":
    proc closeTest(): Future[bool] {.async.} =
      var stream = newBufferStream()
      var
        fut = stream.pushTo(toBytes("hello"))
        fut2 = stream.pushTo(toBytes("again"))
      await stream.close()
      try:
        await wait(fut, 100.milliseconds)
        await wait(fut2, 100.milliseconds)
        result = true
      except AsyncTimeoutError:
        result = false

      await stream.close()

      check:
        waitFor(closeTest()) == true

  test "no push after close":
    proc closeTest(): Future[bool] {.async.} =
      var stream = newBufferStream()
      await stream.pushTo("123".toBytes())
      var data: array[3, byte]
      await stream.readExactly(addr data[0], data.len)
      await stream.close()

      try:
        await stream.pushTo("123".toBytes())
      except LPStreamClosedError:
        result = true

      check:
        waitFor(closeTest()) == true
