# Mix

A custom protocol designed to enable anonymous communication in peer-to-peer networks.

## Overview

The Mix protocol leverages the Sphinx packet format to ensure sender anonymity and message unlinkability.
It routes messages through a series of mix nodes, effectively concealing the origin of the message.
This implementation is part of a broader effort to integrate anonymity into the libp2p ecosystem.

**Note:** This is a proof-of-concept, not production-ready code.
It serves as a foundation for further development and research into anonymous communication within libp2p networks.
It provides a basis for future development and invites community experimentation and contributions.

## Key Features

- **Sphinx Packet Format**: Guarantees anonymity through fixed-size packets and layered encryption.
- **Random Path Selection**: Routes messages through randomly selected mix nodes.
- **Pluggable Components**: Allows for customizable spam protection, peer discovery, and incentivization mechanisms. (To be developed)

## Usage

```nim
let mixProto = MixProtocol.new(index, numberOfNodes, switch).valueOr:
  error "Mix protocol initialization failed", err = error
  return

# Exit node will forward any message it receives to its destination,
# but if the protocol requires reading a response, we need to 
# register how should the exit node will read them.
# Use either readExactly or readLp.
# In this example we assume we're gonna use Ping protocol
mixProto.registerDestReadBehavior(PingCodec, readExactly(32))

let pingProto = Ping.new()

switch.mount(mixProto)
switch.mount(pingProto)

await switch.start()

let conn = mixProto.toConnection(
    MixDestination.init(thePeerId, theMultiAddr[0]),
    PingCodec,
    MixParameters(expectReply: Opt.some(true)),
  ).valueOr:
  error "Could not obtain connection", err = error
  return

let response = await pingProto.ping(conn)
```


## Using experimental `exit == destination`

1. Compile with: `-d:libp2p_mix_experimental_exit_is_dest`
2. In `toConnection` you can now specify the behavior the exit node will have:`

```nim
# Exit != destination (the default)
# The exit node will forward the request to the destination
# You can also use MixDestination.init instead
let theDestination = MixDestination.forwardToAddr(thePeerId, theMultiAddress)
let conn = mixProto.toConnection(
    theDestination,
    theCodec,
  ).expect("should build connection")


# Exit == destination
# The protocol handler will be executed at the exit node
let theDestination = MixDestination.exitNode(thePeerId)
let conn = mixProto.toConnection(
    theDestination,
    theCodec,
  ).expect("should build connection")
```



## RFC and Further Reading

For a detailed technical specification and discussion, please refer to the [Mix Protocol RFC](https://rfc.vac.dev/vac/raw/mix/).

## Acknowledgments

Thanks to the libp2p community and all contributors for their feedback and insights throughout the development
of the Mix protocol.
