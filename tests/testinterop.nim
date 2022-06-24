import helpers, commoninterop
import ../libp2p
import ../libp2p/crypto/crypto

proc switchMplexCreator(
    isRelay: bool = false,
    ma: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()): Switch =

  SwitchBuilder.new()
    .withSignedPeerRecord(false)
    .withMaxConnections(MaxConnections)
    .withRng(crypto.newRng())
    .withAddresses(@[ ma ])
    .withMaxIn(-1)
    .withMaxOut(-1)
    .withTcpTransport()
    .withMplex()
    .withMaxConnsPerPeer(MaxConnectionsPerPeer)
    .withPeerStore(capacity=1000)
    .withNoise()
    .withRelayTransport(isRelay)
    .withNameResolver(nil)
    .build()

proc switchYamuxCreator(
    isRelay: bool = false,
    ma: MultiAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()): Switch =

  SwitchBuilder.new()
    .withSignedPeerRecord(false)
    .withMaxConnections(MaxConnections)
    .withRng(crypto.newRng())
    .withAddresses(@[ ma ])
    .withMaxIn(-1)
    .withMaxOut(-1)
    .withTcpTransport()
    .withYamux()
    .withMaxConnsPerPeer(MaxConnectionsPerPeer)
    .withPeerStore(capacity=1000)
    .withNoise()
    .withRelayTransport(isRelay)
    .withNameResolver(nil)
    .build()


suite "Interop mplex":
  commonInteropTests("mplex", switchMplexCreator)
  relayInteropTests("mplex", switchMplexCreator)

  commonInteropTests("yamux", switchYamuxCreator)
  relayInteropTests("yamux", switchYamuxCreator)
