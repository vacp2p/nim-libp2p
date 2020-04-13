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
        for i in @['\5', 'a', 'b', 'c', 'd', 'e']:
          var fut = newFuture[seq[byte]]()
          fut.complete(cast[seq[byte]](@[i]))
          yield fut

      var decoded: seq[byte]
      var decodeStream = lp.decode(stream)
      for i in decodeStream():
        decoded.add(await i)

      check:
        decoded == cast[seq[byte]](@['a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true

  test "pipe":
    proc test(): Future[bool] {.async.} =
      var lp = LenPrefixed.init()
      iterator source(): Future[seq[byte]] {.closure.} =
        for i in @['a', 'b', 'c', 'd', 'e']:
          var fut = newFuture[seq[byte]]()
          fut.complete(cast[seq[byte]](@[i]))
          yield fut

      var decoded: seq[byte]
      var decodeStream = lp.decode(lp.encode(source))
      for i in decodeStream():
        decoded.add(await i)

      check:
        decoded == cast[seq[byte]](@['a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true
