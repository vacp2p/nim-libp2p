{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/wstransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers, ./commontransport

suite "Websocket transport":
  teardown:
    checkTrackers()
  WsTransport.commonTransportTest("/ip4/0.0.0.0/tcp/0/ws")
