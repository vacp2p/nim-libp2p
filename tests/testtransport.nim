import unittest
import chronos
import ../libp2p/connection, ../libp2p/transport, ../libp2p/tcptransport,
    ../libp2p/multiaddress, ../libp2p/wire

suite "TCP transport suite":
  test "test listener":
    proc testListener(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53335")
      proc connHandler(conn: Connection): Future[void] {.async ,gcsafe.} =
        result = conn.write(cstring("Hello!"), 6)

      let transport: TcpTransport = newTransport(TcpTransport, ma, connHandler)
      await transport.listen()
      let streamTransport: StreamTransport = await connect(ma)
      let msg = await streamTransport.read(6)
      result = cast[string](msg) == "Hello!"

    check:
       waitFor(testListener()) == true
