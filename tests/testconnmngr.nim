import unittest
import ../libp2p/[connmanager,
                  stream/connection,
                  crypto/crypto,
                  muxers/muxer,
                  peerinfo]

let rng = newRng()
let peer = PeerInfo.init(PrivateKey.random(ECDSA, rng[]).tryGet())

suite "Connection Manager":
  test "add and retrive a connection":
    let connMngr = ConnManager.init()
    let conn = Connection.init(peer, Direction.In)

    connMngr.storeConn(conn)
    check conn in connMngr

    let peerConn = connMngr.selectConn(peer)
    check peerConn == conn
    check peerConn.dir == Direction.In

  test "add and retrieve a muxer":
    let connMngr = ConnManager.init()
    let conn = Connection.init(peer, Direction.In)
    let muxer = new Muxer
    muxer.connection = conn

    connMngr.storeConn(conn)
    connMngr.storeMuxer(muxer)
    check muxer in connMngr

    let peerMuxer = connMngr.selectMuxer(conn)
    check peerMuxer == muxer
