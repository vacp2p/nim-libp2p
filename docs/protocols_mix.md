[← Back to README](../README.md)

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
- **Spam Protection Interface**: Standardized interface for integrating spam protection mechanisms. See [Spam Protection](protocols_mix_spam_protection.md) for details.
- **Pluggable Components**: Allows for customizable peer discovery and incentivization mechanisms. (To be developed)

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

## Spam Protection

The Mix protocol includes a flexible spam protection interface that allows custom mechanisms to be integrated. By default, spam protection is disabled (nil).

```nim
# Create a custom spam protection instance
let spamProtection = MySpamProtection.new()

# Initialize MixProtocol with spam protection
let mixProto = MixProtocol.new(
  mixNodeInfo,
  pubNodeInfo,
  switch,
  spamProtection = spamProtection
)
```

For detailed information on implementing custom spam protection mechanisms, see [Spam Protection](protocols_mix_spam_protection.md).

## Using experimental `exit == destination`

1. Compile with: `-d:libp2p_mix_experimental_exit_is_dest`
2. In `toConnection` you can now specify the behavior the exit node will have:

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

## Example

A complete working example demonstrating the Mix protocol with Ping can be found at [examples/mix_ping.nim](../examples/mix_ping.nim).

## RFC and Further Reading

For a detailed technical specification and discussion, please refer to the [Mix Protocol RFC](https://lip.logos.co/ift-ts/raw/mix.html).

## Acknowledgments

Thanks to the libp2p community and all contributors for their feedback and insights throughout the development
of the Mix protocol.

---

[← Back to README](../README.md)
