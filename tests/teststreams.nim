import unittest
import chronos
import streams/[stream,
                pushable,
                chronosstream,
                connection,
                utils]

suite "streams":
  test "interuption":
    proc test() {.async.} =
      iterator source(): Future[int] {.closure.} =
        for i in 0..5:
          if i == 4:
            break

          yield i.toFuture

      proc sink(i: Source[int]): Future[void] {.async.} =
        var count = 0
        for item in i:
          discard await item
          count.inc

        check: count == 4

      await source.sink()

    waitFor(test())
