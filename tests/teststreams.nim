import unittest
import chronos, chronicles, stew/byteutils
import multiaddress,
       transports/[transport, tcptransport],
       streams/[stream,
               writable,
               chronosstream,
               connection,
               writable,
               utils]

suite "streams":
  # test "interuption":
  #   proc test() {.async.} =
  #     iterator source(): Future[int] {.closure.} =
  #       for i in 0..5:
  #         if i == 4:
  #           break

  #         yield i.toFuture

  #     proc sink(i: Source[int]): Future[void] {.async.} =
  #       var count = 0
  #       for item in i:
  #         echo await item
  #         count.inc

  #       check: count == 4

  #     await source.sink()

  #   waitFor(test())

  # test "error propagation":
  #   proc test() {.async.} =
  #     iterator source(): Future[int] {.closure.} =
  #       for i in 0..5:
  #         if i == 4:
  #           raise newException(CatchableError, "Uh-Oh!")

  #         yield i.toFuture

  #     proc sink(i: Source[int]): Future[void] {.async.} =
  #       var count = 0
  #       for item in i:
  #         echo await item
  #         count.inc

  #       check: count == 4

  #     try:
  #       await source.sink()
  #     except CatchableError as exc:
  #       check: true

  #   waitFor(test())

  # test "error propagation with pipeline":
  #   proc test() {.async.} =
  #     iterator source(): Future[int] {.closure.} =
  #       defer:
  #         echo "exiting source"

  #       for i in 0..5:
  #         if i == 4:
  #           raise newException(CatchableError, "Uh-Oh!")

  #         yield i.toFuture

  #     proc sink(i: Source[int]): Future[void] {.async.} =
  #       defer:
  #         echo "exiting sink"

  #       var count = 0
  #       for item in i:
  #         echo await item
  #         count.inc

  #       check: count == 4

  #     proc mul2(f: Future[int]): Future[int] {.async.} =
  #       result = (await f) * 2

  #     proc through1(i: Source[int]): Source[int] {.gcsafe.} =
  #       return iterator(): Future[int] {.closure.} =
  #         defer:
  #           echo "exiting through1"

  #         for item in i:
  #           yield mul2(item)

  #     proc through2(i: Source[int]): Source[int] {.gcsafe.} =
  #       return iterator(): Future[int] {.closure.} =
  #         defer:
  #           echo "exiting through2"

  #         for item in i:
  #           yield mul2(item)
  #         echo "exiting through2"

  #     try:
  #       await source.
  #             through1.
  #             through2.
  #             sink
  #     except CatchableError as exc:
  #       check: true

  #   waitFor(test())

  # test "resource destruction":
  #   proc test() {.async.} =
  #     type
  #       MyType = object of RootObj
  #         inner: string

  #       MyTypeRef = ref MyType

  #     proc `=destroy`(t: var MyType) =
  #       echo "destroyed!"

  #     iterator source(): Future[MyTypeRef] {.closure.} =
  #       for i in 0..5:
  #         yield MyTypeRef().toFuture
  #         if i == 4:
  #           raise newException(CatchableError, "Uh-Oh!")

  #     proc sink(i: Source[MyTypeRef]): Future[void] {.async.} =
  #       var count = 0
  #       for item in i:
  #         discard await item
  #         count.inc

  #       check: count == 4

  #     proc through1(i: Source[MyTypeRef]): Source[MyTypeRef] {.gcsafe.} =
  #       return iterator(): Future[MyTypeRef] {.closure.} =
  #         for item in i:
  #           yield item

  #     proc through2(i: Source[MyTypeRef]): Source[MyTypeRef] {.gcsafe.} =
  #       return iterator(): Future[MyTypeRef] {.closure.} =
  #         for item in i:
  #           yield item

  #     try:
  #       await source.
  #             through1.
  #             through2.
  #             sink
  #     except CatchableError as exc:
  #       check: true

  #     await sleepAsync(500.millis)

  #   waitFor(test())

  # test "writable should not terminate prematurely":
  #   proc test() {.async.} =
  #     var writable: Writable[string] = Writable[string].init(eofTag = "\0")

  #     var dest: Sink[string] = proc (i: Source[string]): Future[void] {.async.} =
  #       for item in i:
  #         echo await item

  #     var sink = pipe(writable, dest)

  #     await writable.write("item 1")
  #     # await writable.write("item 2")
  #     # await writable.write("item 3")
  #     await writable.close()

  #     await sink

  #   waitFor(test())

  test "writable should not terminate prematurely":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var finished = newFuture[void]()
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        var source = conn.source()
        for i in source:
          var msg = await i
          if msg.len <= 0:
            break
          echo "STREAM ", string.fromBytes(msg)
        finished.complete()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let transportFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      # iterator source(): Future[seq[byte]] {.closure.} =
      #   var count = 0
      #   proc src(): Future[seq[byte]] =
      #     result = (("item " & $count).toBytes()).toFuture

      #   while true:
      #     var res = src()
      #     echo "HERE 1"
      #     if count > 2:
      #       break
      #     count.inc

      #     echo "HERE 2"
      #     yield res
      #     echo "HERE 3"
      #   echo "DONE!"

      # var sink = conn.sink()(source)

      var writable = ByteWritable.init()
      var sink = pipe(writable, conn)

      await writable.write("item 1".toBytes())
      await writable.write("item 2".toBytes())
      await writable.write("item 3".toBytes())
      await writable.close()

      await finished
      await transport1.close()
      await transportFut
      await sink

    waitFor(test())
