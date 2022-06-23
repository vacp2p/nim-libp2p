import options
import chronos, strutils, sequtils, sets, algorithm
import ../libp2p/[protocols/identify,
                  multiaddress,
                  peerinfo,
                  peerid,
                  stream/connection,
                  multistream,
                  transports/transport,
                  switch,
                  builders,
                  transports/tcptransport,
                  crypto/crypto,
                  upgrademngrs/upgrade]
import ./helpers

when defined(nimHasUsed): {.used.}

suite "Identify":
  teardown:
    checkTrackers()

  suite "handle identify message":
    var
      ma {.threadvar.}: seq[MultiAddress]
      remoteSecKey {.threadvar.}: PrivateKey
      remotePeerInfo {.threadvar.}: PeerInfo
      serverFut {.threadvar.}: Future[void]
      acceptFut {.threadvar.}: Future[void]
      identifyProto1 {.threadvar.}: Identify
      identifyProto2 {.threadvar.}: Identify
      transport1 {.threadvar.}: Transport
      transport2 {.threadvar.}: Transport
      msListen {.threadvar.}: MultistreamSelect
      msDial {.threadvar.}: MultistreamSelect
      conn {.threadvar.}: Connection

    asyncSetup:
      ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      remoteSecKey = PrivateKey.random(ECDSA, rng[]).get()
      remotePeerInfo = PeerInfo.new(
        remoteSecKey,
        ma,
        ["/test/proto1/1.0.0", "/test/proto2/1.0.0"])

      transport1 = TcpTransport.new(upgrade = Upgrade())
      transport2 = TcpTransport.new(upgrade = Upgrade())

      identifyProto1 = Identify.new(remotePeerInfo)
      identifyProto2 = Identify.new(remotePeerInfo)

      msListen = MultistreamSelect.new()
      msDial = MultistreamSelect.new()

    asyncTeardown:
      await conn.close()
      await acceptFut
      await transport1.stop()
      await serverFut
      await transport2.stop()

    asyncTest "default agent version":
      msListen.addHandler(IdentifyCodec, identifyProto1)
      serverFut = transport1.start(ma)
      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let c = await transport1.accept()
        await msListen.handle(c)

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.addrs[0])

      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo.peerId)

      check id.pubkey.get() == remoteSecKey.getPublicKey().get()
      check id.addrs == ma
      check id.protoVersion.get() == ProtoVersion
      check id.agentVersion.get() == AgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
      check id.signedPeerRecord.isNone()

    asyncTest "custom agent version":
      const customAgentVersion = "MY CUSTOM AGENT STRING"
      remotePeerInfo.agentVersion = customAgentVersion
      msListen.addHandler(IdentifyCodec, identifyProto1)

      serverFut = transport1.start(ma)

      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let c = await transport1.accept()
        await msListen.handle(c)

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.addrs[0])

      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo.peerId)

      check id.pubkey.get() == remoteSecKey.getPublicKey().get()
      check id.addrs == ma
      check id.protoVersion.get() == ProtoVersion
      check id.agentVersion.get() == customAgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
      check id.signedPeerRecord.isNone()

    asyncTest "handle failed identify":
      msListen.addHandler(IdentifyCodec, identifyProto1)
      asyncSpawn transport1.start(ma)

      proc acceptHandler() {.async.} =
        var conn: Connection
        try:
          conn = await transport1.accept()
          await msListen.handle(conn)
        except CatchableError:
          discard
        finally:
          await conn.close()

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.addrs[0])

      expect IdentityNoMatchError:
        let pi2 = PeerInfo.new(PrivateKey.random(ECDSA, rng[]).get())
        discard await msDial.select(conn, IdentifyCodec)
        discard await identifyProto2.identify(conn, pi2.peerId)

    asyncTest "can send signed peer record":
      msListen.addHandler(IdentifyCodec, identifyProto1)
      identifyProto1.sendSignedPeerRecord = true
      serverFut = transport1.start(ma)
      proc acceptHandler(): Future[void] {.async, gcsafe.} =
        let c = await transport1.accept()
        await msListen.handle(c)

      acceptFut = acceptHandler()
      conn = await transport2.dial(transport1.addrs[0])

      discard await msDial.select(conn, IdentifyCodec)
      let id = await identifyProto2.identify(conn, remotePeerInfo.peerId)

      check id.pubkey.get() == remoteSecKey.getPublicKey().get()
      check id.addrs == ma
      check id.protoVersion.get() == ProtoVersion
      check id.agentVersion.get() == AgentVersion
      check id.protos == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
      check id.signedPeerRecord.get() == remotePeerInfo.signedPeerRecord.envelope

  suite "handle push identify message":
    var
      switch1 {.threadvar.}: Switch
      switch2 {.threadvar.}: Switch
      identifyPush1 {.threadvar.}: IdentifyPush
      identifyPush2 {.threadvar.}: IdentifyPush
      conn {.threadvar.}: Connection
    asyncSetup:
      switch1 = newStandardSwitch()
      switch2 = newStandardSwitch()

      proc updateStore1(peerId: PeerId, info: IdentifyInfo) {.async.} =
        switch1.peerStore.updatePeerInfo(info)
      proc updateStore2(peerId: PeerId, info: IdentifyInfo) {.async.} =
        switch2.peerStore.updatePeerInfo(info)

      identifyPush1 = IdentifyPush.new(updateStore1)
      identifyPush2 = IdentifyPush.new(updateStore2)

      switch1.mount(identifyPush1)
      switch2.mount(identifyPush2)

      await switch1.start()
      await switch2.start()

      conn = await switch2.dial(
        switch1.peerInfo.peerId,
        switch1.peerInfo.addrs,
        IdentifyPushCodec)

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs
        switch2.peerStore[AddressBook][switch1.peerInfo.peerId] == switch1.peerInfo.addrs

        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs
        switch2.peerStore[AddressBook][switch1.peerInfo.peerId] == switch1.peerInfo.addrs

        #switch1.peerStore.signedPeerRecordBook.get(switch2.peerInfo.peerId) == switch2.peerInfo.signedPeerRecord.get()
        #switch2.peerStore.signedPeerRecordBook.get(switch1.peerInfo.peerId) == switch1.peerInfo.signedPeerRecord.get()
        # no longer sent by default

    proc closeAll() {.async.} =
      await conn.close()

      await switch1.stop()
      await switch2.stop()

    asyncTest "simple push identify":
      switch2.peerInfo.protocols.add("/newprotocol/")
      switch2.peerInfo.addrs.add(MultiAddress.init("/ip4/127.0.0.1/tcp/5555").tryGet())

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] != switch2.peerInfo.addrs
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] != switch2.peerInfo.protocols

      await identifyPush2.push(switch2.peerInfo, conn)

      check await checkExpiring(switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] == switch2.peerInfo.protocols)
      check await checkExpiring(switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs)

      await closeAll()

      # Wait the very end to be sure that the push has been processed
      check:
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] == switch2.peerInfo.protocols
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs


    asyncTest "wrong peer id push identify":
      switch2.peerInfo.protocols.add("/newprotocol/")
      switch2.peerInfo.addrs.add(MultiAddress.init("/ip4/127.0.0.1/tcp/5555").tryGet())

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] != switch2.peerInfo.addrs
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] != switch2.peerInfo.protocols

      let oldPeerId = switch2.peerInfo.peerId
      switch2.peerInfo = PeerInfo.new(PrivateKey.random(newRng()[]).get())

      await identifyPush2.push(switch2.peerInfo, conn)

      # We have no way to know when the message will is received
      # because it will fail validation inside push identify itself
      #
      # So no choice but to sleep
      await sleepAsync(10.milliseconds)

      await closeAll()

      # Wait the very end to be sure that the push has been processed
      check:
        switch1.peerStore[ProtoBook][oldPeerId] != switch2.peerInfo.protocols
        switch1.peerStore[AddressBook][oldPeerId] != switch2.peerInfo.addrs
