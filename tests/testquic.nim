{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/quictransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers, ./commontransport

suite "Quic transport":
  asyncTest "can handle local address":
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic").tryGet()]
    let transport1 = QuicTransport.new()
    await transport1.start(ma)
    check transport1.handles(transport1.addrs[0])
    await transport1.stop()
