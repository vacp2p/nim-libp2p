In the [previous tutorial](tutorial_1_connect.md), we've looked at how to create a simple ping program using the `nim-libp2p`.

We'll now look at how to create a custom protocol inside the libp2p

# Custom protocol in libp2p
Let's create a `part2.nim`, and import our dependencies:
```nim
import bearssl
import chronos
import stew/byteutils

import libp2p
```
This is similar to the first tutorial, except we don't need to import the `Ping` protocol.

Next, we'll declare our custom protocol:
```nim
const TestCodec = "/test/proto/1.0.0"

type TestProto = ref object of LPProtocol
```

We've set a [protocol ID](https://docs.libp2p.io/concepts/protocols/#protocol-ids), and created a custom `LPProtocol`. In a more complex protocol, we could use this structure to store interesting variables.

A protocol generally has two parts: a handling/server part, and a dialing/client part. These two parts can be identical, but in our trivial protocol, the server will wait for a message from the client, and the client will send a message, so we have to handle the two cases separately.

Let's start with the server part:
```nim
proc new(T: typedesc[TestProto]): T =
  # every incoming connections will be handled in this closure
  proc handle(stream: Connection, proto: string) {.async, gcsafe.} =
    echo "[server] received from client: ", string.fromBytes(await stream.readLp(1024))
    await stream.writeLp("Hi back!")
    # We must close the stream ourselves when we're done with it
    await stream.close()

  return T(codecs: @[TestCodec], handler: handle)
```
This is a constructor for our `TestProto`, that will specify our `codecs` and a `handler`, which will be called for each incoming peer asking for this protocol.

In our handle, we simply read a message from the stream and `echo` it.

We can now create our client part:
```nim
proc hello(p: TestProto, stream: Connection) {.async.} =
  await stream.writeLp("Hello p2p!")
  let
    # readLp reads length prefixed bytes and returns a buffer without the prefix
    strData = await stream.readLp(1024)
    str = string.fromBytes(strData)
  echo "[client] received from server: ", str
```
Again, pretty straight-forward, we just send a message on the stream.

We can now create our main procedure:
```nim
proc main() {.async, gcsafe.} =
  let
    rng = newRng()
    testProto = TestProto.new()
    switch1 = newStandardSwitch(rng=rng)
    switch2 = newStandardSwitch(rng=rng)
  
  switch1.mount(testProto)
  
  await switch1.start()
  await switch2.start()
    
  let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, TestCodec)

  await testProto.hello(conn)

  # We must close the stream ourselves when we're done with it
  await stream.close()

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
```

This is very similar to the first tutorial's `main`. The only noteworthy difference is that we use `newStandardSwitch`, which is similar to `createSwitch` but is bundled directly in libp2p.

We can now wrap our program by calling our main proc:
```nim
waitFor(main())
```

And that's it! In the [next tutorial](tutorial_3_streamproto.md), we'll look at how to create a protocol for streaming data.
