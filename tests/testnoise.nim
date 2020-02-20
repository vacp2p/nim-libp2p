## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import unittest
import chronos
import ../libp2p/crypto/crypto
import ../libp2p/protocols/secure/noise
import ../libp2p/[connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress]


suite "Noise":
  test "XX handshake":
    proc testListenerDialer(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        echo "Init <-"
        
        let
          pk = PrivateKey.random(RSA)
          noise = newNoise(pk, false)
          secured = await noise.secure(conn)
        
        result = conn.write(cstring("Hello!"), 6)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      echo "Init ->"
      
      let
        pk = PrivateKey.random(RSA)
        noise = newNoise(pk, true)
        secured = await noise.secure(conn)
      
      let msg = await conn.read(6)
      await transport1.close()

      result = cast[string](msg) == "Hello!"

    check:
      waitFor(testListenerDialer()) == true
