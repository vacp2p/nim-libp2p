# Simple ping

Hi, let's make a ping. First we need to import libp2p
```nim
import bearssl
import chronos
import libp2p
import libp2p/protocols/ping
```

Then we need to create a switch etc
```nim
proc createSwitch(ma: MultiAddress, rng: ref BrHmacDrbgContext): Switch =
  var switch = SwitchBuilder
    .new()
    .withRng(rng)       # Give the application RNG
    .withAddress(ma)    # Our local address(es)
    .withTcpTransport() # Use TCP as transport
    .withMplex()        # Use Mplex as muxer
    .withNoise()        # Use Noise as secure manager
    .build()

  result = switch

```

We can then create our actual program..
```nim
proc main() {.async, gcsafe.} =
  let
    rng = newRng() # Single random number source for the whole application
    # port 0 will take a random available port
    # `tryGet` will throw an exception if the Multiaddress failed
    # (for instance, if the address is not well formatted)
    ma1 = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
    ma2 = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

  # setup the two nodes
  let
    switch1 = createSwitch(ma1, rng) #Create the two switches
    switch2 = createSwitch(ma2, rng)

    pingProtocol = Ping.new(rng=rng)

  # mount the ping proto on switch1
  # the node will now listen for this proto
  switch1.mount(pingProtocol)

  # Start the nodes. This will start the transports
  # and listen on each local addresses
  let
    switch1Fut = await switch1.start()
    switch2Fut = await switch2.start()

  # the node addrs is populated with it's
  # actual port during the start

  # use the second node to dial the first node
  # using the first node peerid and address
  # and specify the ping protocol codec
  let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, PingCodec)

  # ping the other node and echo the ping duration
  echo "ping: ", await pingProtocol.ping(conn)

  # We must close the connection ourselves when we're done with it
  await conn.close()

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports
  await allFutures(switch1Fut & switch2Fut) # wait for all transports to shutdown

waitFor(main())
```

# Custom protocol
```nim
import libp2p

echo "second tutorial!"
```
