import unittest
import chronos
import ../libp2p/streams/[lenprefixed, stream]

suite "LenPrefixed stream":
  test "encode":
    proc test(): Future[bool] {.async.} =
      var lp = LenPrefixed.init()
      iterator stream(): Future[seq[byte]] {.closure.} =
        var fut = newFuture[seq[byte]]()
        fut.complete(cast[seq[byte]](@['a', 'b', 'c', 'd', 'e']))
        yield fut

      var encode = lp.encoder()
      var encoded: seq[byte]

      for i in stream.encode():
        encoded = await i

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
      var decode = lp.decoder()

      for i in stream.decode():
        decoded.add(await i)

      check:
        decoded == cast[seq[byte]](@['a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true

  test "pipe":
    proc test(): Future[bool] {.async.} =
      var lp = LenPrefixed.init()
      iterator stream(): Future[seq[byte]] {.closure.} =
        for i in @['a', 'b', 'c', 'd', 'e']:
          var fut = newFuture[seq[byte]]()
          fut.complete(cast[seq[byte]](@[i]))
          yield fut

      var decoded: seq[byte]
      var decode = lp.decoder()
      var encode = lp.encoder()

      for i in stream.encode.decode():
        decoded.add(await i)

      check:
        decoded == cast[seq[byte]](@['a', 'b', 'c', 'd', 'e'])
      result = true

    check:
      waitFor(test()) == true
