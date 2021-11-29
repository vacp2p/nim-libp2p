In the [previous tutorial](tutorial_3_streamproto.md), we learned how to create a custom streaming protocol.

This tutorial is very similar to the [previous tutorial](tutorial_3_streamproto.md) in that a stream of data will be consumed, however in this tutorial we will learn how to use alternative libp2p streaming semantics.

# Custom protocol in libp2p
Let's create a `part4.nim`, and import our dependencies:
```nim
import bearssl
import chronos
import stew/byteutils

import libp2p
```
This is similar to the third tutorial. Next, we'll declare our custom protocol.
```nim
const TestStreamCodec = "/test/stream-proto/2.0.0"

type TestStreamProto = ref object of LPProtocol
```

Just as we did in the last tutorial, we've set a [protocol ID](https://docs.libp2p.io/concepts/protocols/#protocol-ids), and created a custom `LPProtocol`.

As in the last tutorial, we are going to handle our client and server parts separately. The server will wait for an instruction from the client, then send a stream of data to the client and finish by closing the connection. The client will listen in a loop until the server has finished and closed the connection. Then the client will close its end of the connection as well.

Let's start with the server part:
```nim
# Set the chunk length >= any data being streamed. Our longest chunk of data in
# either direction is 16 bytes ("please send data").
const CHUNK_LEN_BYTES = 16

proc new(T: typedesc[TestStreamProto]): T =
  # every incoming connections will in be handled in this closure
  var buf = newSeq[byte](CHUNK_LEN_BYTES)
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} =

    discard await stream.readOnce(addr buf[0], CHUNK_LEN_BYTES)
    echo "[server] received from client: ", string.fromBytes(buf)

    # send stream of data
    for i in 0..10:
      let data = "Part " & $i
      await stream.write(data)

    # We must close the connections ourselves when we're done with it
    await stream.close()

  return T(codecs: @[TestStreamCodec], handler: handle)
```
Instead of using `readLp` to read data from the connection (as in the previous tutorial), we are going to use `readOnce`, which allows us to read bytes from the buffer or wait for bytes to be received.

We can now create our client part:
```nim
proc streamData(p: TestStreamProto, stream: Connection) {.async.} =
  let data = "please send data"
  await stream.write(data)

  # Read loop
  while not stream.atEof:

    var buf = newSeq[byte](CHUNK_LEN_BYTES)
    # readOnce reads bytes from internal buffer if present, otherwise waits for
    # bytes to be received. Note that it will return as soon as it receive
    # bytes, even if the message is not complete.
    let len = await stream.readOnce(addr buf[0], CHUNK_LEN_BYTES)

    # When the connection is closed from the server end, len will be 0 as we
    # will not have read any data. We could check len == 0 and break the while
    # loop, or we can let the loop continue at which point stream.atEof will be
    # true and the loop will break. The only difference is that by continuing,
    # we will see an extra line echoed with no data received.
    echo "[client] received from server: ", string.fromBytes(buf)

  # close the stream from the client's side
  await stream.close()
```
As a client, we want to keep reading data in a loop until the server has finished sending its stream, then we can close the stream from the client's side as well. We know that the client has closed its stream when `stream.atEof` is `true`. The difference when using `readOnce` instead of `readLp` is that when using `readLp` (to read length-prefixed data), we won't get the chance to read an EOF signaled by a remote closure, requiring us to read again and catch an exception. `readOnce` allows us to finish our read loop once `atEof` is `true`.

We can now create our main procedure:
```nim
proc main() {.async, gcsafe.} =
  let
    rng = newRng()
    TestStreamProto = TestStreamProto.new()
    switch1 = newStandardSwitch(rng=rng)
    switch2 = newStandardSwitch(rng=rng)

  switch1.mount(TestStreamProto)

  await switch1.start()
  await switch2.start()

  let stream = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestStreamCodec)

  # stream is now a fully setup connection, we talk directly to the switch1 custom protocol handler
  await TestStreamProto.streamData(stream)

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
```

This is very similar to the second tutorial's `main`, except that we use our newly created stream protocol and stream codec.

We can now wrap our program by calling our main proc:
```nim
waitFor(main())
```

And that's it!
