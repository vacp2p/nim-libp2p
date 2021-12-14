In the [previous tutorial](tutorial_2_customproto.md), we dug a little deeper in to how the ping protocol works by creating a custom ping protocol ourselves.

This tutorial will focus on how to create a custom streaming protocol using libp2p.

# Custom protocol in libp2p
Let's create a `part3.nim`, and import our dependencies:
```nim
import bearssl
import chronos
import stew/byteutils

import libp2p
```
This is similar to the second tutorial. Next, we'll declare our custom protocol.
```nim
const TestStreamCodec = "/test/stream-proto/1.0.0"

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
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} =
    # readLp reads length prefixed bytes and returns a buffer without the
    # prefix
    var bytes = await stream.readLp(CHUNK_LEN_BYTES)
    echo "[server] received from client: ", string.fromBytes(bytes)

    # send stream of data
    for i in 0..10:
      let data = "Part " & $i
      await stream.writeLp(data)

    # We must close the connections ourselves when we're done with it
    await stream.close()

  return T(codecs: @[TestStreamCodec], handler: handle)
```
Again, `handle`, will be called for each incoming peer asking for this protocol. In our simple example, the client sends `"please send data"` and once received, the server echos the message and sends a stream of data back. In this example, we are simply sending a series of strings as the stream of data, but this can be any data in a practical application.

We can now create our client part:
```nim
proc streamData(p: TestStreamProto, stream: Connection) {.async.} =
  let data = "please send data"
  await stream.writeLp(data)

  # Read loop
  try:

    while true:
      # readLp reads length prefixed bytes and returns a buffer without the
      # prefix
      let bytes = await stream.readLp(CHUNK_LEN_BYTES)

      echo "[client] received from server: ", string.fromBytes(bytes)

  except LPStreamEOFError:
    # close the stream from the client's side
    await stream.close()
```
As a client, we want to keep reading data in a loop until the server has finished sending its stream, then we can close the stream from the client's side as well. We know that the client has closed its stream when `LPStreamEOFError` is raised.

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

In the [next tutorial](tutorial_4_streamproto2.md), we will get a glimpse of an alternative way to stream data.
