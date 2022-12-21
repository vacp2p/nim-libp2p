# Autonat Example

# This example shows how to use the autonat service. This service allows a given
# peer to constantly request other peers to check if it is reachable or not. It can
# be configured with the following parameters:
# -scheduleInterval: how often to check if the peer is reachable
# -askNewConnectedPeers: if true, the service will ask new connected peers
# -numPeersToAsk: how many peers to ask if we are reachable every scheduleInterval
# -maxQueueSize: amount of status responses to store, used to estimate our reachability
# -minConfidence: minimum confidence to consider the peer reachable [0.0 - 1.0]
# -statusAndConfidenceHandler: proc handle to execute on every scheduleInterval

# This example creates two peers: p1, p2, both of them enabling the autonat protocol. Then
# we setup the autonat service for p1 and create an outgoing connection p1->p2.

# Under the hood, the autonat service will keep requesting p2 to dial us, and if it succeeds,
# it will flag our state as Reachable.
# Every scheduleInterval, you should see in the logs:
# confidence=1.0 networkReachability=Reachable

import std/options
import chronos

import libp2p
import libp2p/protocols/ping
import libp2p/protocols/connectivity/autonat
import libp2p/services/autonatservice

proc createSwitch(ma: MultiAddress, rng: ref HmacDrbgContext, services: seq[Service]): Switch =
  var switch = SwitchBuilder
    .new()
    .withRng(rng)
    .withAddress(ma)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withAutonat()           # Enable autonat
    .withServices(services)  # Provide services
    .build()

  return switch

proc main() {.async, gcsafe.} =
  let
    rng = newRng()

    # Peer listeninig in port 1000
    myAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/1000").tryGet()

    # Peer listening in port 2000
    remoteAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/2000").tryGet()
    
    # Create a ping protocol
    pingProtocol = Ping.new(rng=rng)
  
  # TODO: Fix when circular dependancy fixed
  let autonat = Autonat.new()

  let autonatService = AutonatService.new(
    autonat = autonat,
    rng = rng,
    scheduleInterval = some(chronos.seconds(15)),
    askNewConnectedPeers = true,
    numPeersToAsk = 1,
    maxQueueSize = 1,
    minConfidence = 0.5)

  # Function handle to be called every scheduleInterval
  proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
    if confidence.isSome():
      info "statusAndConfidenceHandler", confidence=confidence.get(), networkReachability=networkReachability

  autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)
  var service: Service;
  service = autonatService 

  let
    # My switch contains the autonat service
    mySwitch = createSwitch(myAddress, rng, @[service])

    # The remote switch does not contain the autonat service
    remoteSwitch = createSwitch(remoteAddress, rng, @[])

  # TODO: Fix when circular dependancy fixed
  autonat.switch = mySwitch

  # Mount ping protocol in the remote peer
  remoteSwitch.mount(pingProtocol) 

  # Start both switches
  await mySwitch.start()
  await remoteSwitch.start()

  # Create a connection, so that the autonat service has available peer to request dialMe
  let conn = await mySwitch.dial(remoteSwitch.peerInfo.peerId, remoteSwitch.peerInfo.addrs, PingCodec)

  # And let the autonat service tell us if we are reachable or no
  runForever()

waitFor(main())