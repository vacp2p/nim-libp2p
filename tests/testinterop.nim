import helpers, commoninterop
import ../libp2p
import ../libp2p/crypto/crypto, ../libp2p/protocols/connectivity/relay/relay

proc switchMplexCreator(
    ma: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    prov: TransportProvider = proc(upgr: Upgrade, privateKey: PrivateKey): Transport =
      TcpTransport.new({}, upgr),
    relay: Relay = Relay.new(circuitRelayV1 = true),
): Switch {.raises: [LPError].} =
  SwitchBuilder
  .new()
  .withSignedPeerRecord(false)
  .withMaxConnections(MaxConnections)
  .withRng(crypto.newRng())
  .withAddresses(@[ma])
  .withMaxIn(-1)
  .withMaxOut(-1)
  .withTransport(prov)
  .withMplex()
  .withMaxConnsPerPeer(MaxConnectionsPerPeer)
  .withPeerStore(capacity = 1000)
  .withNoise()
  .withCircuitRelay(relay)
  .withNameResolver(nil)
  .build()

proc switchYamuxCreator(
    ma: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    prov: TransportProvider = proc(upgr: Upgrade, privateKey: PrivateKey): Transport =
      TcpTransport.new({}, upgr),
    relay: Relay = Relay.new(circuitRelayV1 = true),
): Switch {.raises: [LPError].} =
  SwitchBuilder
  .new()
  .withSignedPeerRecord(false)
  .withMaxConnections(MaxConnections)
  .withRng(crypto.newRng())
  .withAddresses(@[ma])
  .withMaxIn(-1)
  .withMaxOut(-1)
  .withTransport(prov)
  .withYamux()
  .withMaxConnsPerPeer(MaxConnectionsPerPeer)
  .withPeerStore(capacity = 1000)
  .withNoise()
  .withCircuitRelay(relay)
  .withNameResolver(nil)
  .build()

suite "Tests interop":
  commonInteropTests("mplex", switchMplexCreator)
  relayInteropTests("mplex", switchMplexCreator)

  commonInteropTests("yamux", switchYamuxCreator)
  relayInteropTests("yamux", switchYamuxCreator)
