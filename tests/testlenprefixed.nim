import unittest
import chronos
import ../libp2p/stream/lenprefixed

suite "LenPrefixed stream":
  test "encode":
    proc test(): Future[bool] {.async.} =
      var lp = LenPrefixed.init()
      iterator stream(): Future[seq[byte]] {.closure.} =
        var fut = newFuture[seq[byte]]()
        fut.complete(cast[seq[byte]](@['a', 'b', 'c', 'd', 'e']))
        yield fut

      var encoded = await lp.encode(stream)()
      check:
        encoded == cast[seq[byte]](@['\5', 'a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true

  test "decode":
    proc test(): Future[bool] {.async.} =
      var lp = LenPrefixed.init()
      iterator stream(): Future[seq[byte]] {.closure.} =
        var fut = newFuture[seq[byte]]()
        fut.complete(cast[seq[byte]](@['\5', 'a', 'b', 'c', 'd', 'e']))
        yield fut

      var decoded = await lp.decode(stream)()
      check:
        decoded == cast[seq[byte]](@['a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true
