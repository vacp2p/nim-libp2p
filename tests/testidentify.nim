{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options
import chronos
import
  ../libp2p/[
    protocols/identify,
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
    upgrademngrs/upgrade,
  ]
import ./helpers

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
      remotePeerInfo =
        PeerInfo.new(remoteSecKey, ma, ["/test/proto1/1.0.0", "/test/proto2/1.0.0"])

      transport1 = TcpTransport.new(upgrade = Upgrade())
      transport2 = TcpTransport.new(upgrade = Upgrade())

      identifyProto1 = Identify.new(remotePeerInfo)
      identifyProto2 = Identify.new(remotePeerInfo)

      msListen = MultistreamSelect.new()
      msDial = MultistreamSelect.new()

      serverFut = transport1.start(ma)
      await remotePeerInfo.update()

    asyncTeardown:
      await conn.close()
      await acceptFut
      await transport1.stop()
      await serverFut
      await transport2.stop()

    asyncTest "default agent version":
      msListen.addHandler(IdentifyCodec, identifyProto1)
      proc acceptHandler(): Future[void] {.async.} =
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

      proc acceptHandler(): Future[void] {.async.} =
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
      proc acceptHandler(): Future[void] {.async.} =
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
      switch1 = newStandardSwitch(sendSignedPeerRecord = true)
      switch2 = newStandardSwitch(sendSignedPeerRecord = true)

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
        switch1.peerInfo.peerId, switch1.peerInfo.addrs, IdentifyPushCodec
      )

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs
        switch2.peerStore[AddressBook][switch1.peerInfo.peerId] == switch1.peerInfo.addrs

        switch1.peerStore[KeyBook][switch2.peerInfo.peerId] == switch2.peerInfo.publicKey
        switch2.peerStore[KeyBook][switch1.peerInfo.peerId] == switch1.peerInfo.publicKey

        switch1.peerStore[AgentBook][switch2.peerInfo.peerId] ==
          switch2.peerInfo.agentVersion
        switch2.peerStore[AgentBook][switch1.peerInfo.peerId] ==
          switch1.peerInfo.agentVersion

        switch1.peerStore[ProtoVersionBook][switch2.peerInfo.peerId] ==
          switch2.peerInfo.protoVersion
        switch2.peerStore[ProtoVersionBook][switch1.peerInfo.peerId] ==
          switch1.peerInfo.protoVersion

        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] ==
          switch2.peerInfo.protocols
        switch2.peerStore[ProtoBook][switch1.peerInfo.peerId] ==
          switch1.peerInfo.protocols

        switch1.peerStore[SPRBook][switch2.peerInfo.peerId] ==
          switch2.peerInfo.signedPeerRecord.envelope
        switch2.peerStore[SPRBook][switch1.peerInfo.peerId] ==
          switch1.peerInfo.signedPeerRecord.envelope

    proc closeAll() {.async.} =
      await conn.close()

      await switch1.stop()
      await switch2.stop()

    asyncTest "simple push identify":
      switch2.peerInfo.protocols.add("/newprotocol/")
      switch2.peerInfo.addrs.add(MultiAddress.init("/ip4/127.0.0.1/tcp/5555").tryGet())

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] != switch2.peerInfo.addrs
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] !=
          switch2.peerInfo.protocols

      await identifyPush2.push(switch2.peerInfo, conn)

      checkUntilTimeout:
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] ==
          switch2.peerInfo.protocols
      checkUntilTimeout:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] == switch2.peerInfo.addrs

      await closeAll()

    asyncTest "wrong peer id push identify":
      switch2.peerInfo.protocols.add("/newprotocol/")
      switch2.peerInfo.addrs.add(MultiAddress.init("/ip4/127.0.0.1/tcp/5555").tryGet())

      check:
        switch1.peerStore[AddressBook][switch2.peerInfo.peerId] != switch2.peerInfo.addrs
        switch1.peerStore[ProtoBook][switch2.peerInfo.peerId] !=
          switch2.peerInfo.protocols

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
