{.used.}

import strformat, results, unittest2
import ../../libp2p/[crypto/crypto, crypto/secp, multiaddress, multicodec, peerid]
import ../../libp2p/protocols/mix/[curve25519, mix_node]

suite "Mix Node Tests":
  var mixNodes {.threadvar.}: MixNodes

  setup:
    const count = 5
    let mixNodes = initializeMixNodes(count).expect("could not generate mix nodes")
    check:
      mixNodes.len == count

  teardown:
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  test "get mix node by index":
    for i in 0 ..< count:
      let node = mixNodes[i]
      let
        (peerId, multiAddr, mixPubKey, mixPrivKey, libp2pPubKey, libp2pPrivKey) =
          node.get()
        pubKeyProto = PublicKey(scheme: Secp256k1, skkey: libp2pPubKey)
        expectedPeerId = PeerId.init(pubKeyProto).get()
        expectedMA = MultiAddress.init(fmt"/ip4/0.0.0.0/tcp/{4242 + i}").tryGet()
      check:
        peerId == expectedPeerId
        multiAddr == expectedMA
        fieldElementToBytes(mixPubKey).len == FieldElementSize
        fieldElementToBytes(mixPrivKey).len == FieldElementSize
        libp2pPubKey.getBytes().len == SkRawPublicKeySize
        libp2pPrivKey.getBytes().len == SkRawPrivateKeySize

  test "find mixnode by peerid":
    for i in 0 ..< count:
      let
        node = mixNodes[i]
        foundNode = mixNodes.findByPeerId(node.peerId).expect("find mix node error")

      check:
        foundNode == node

  test "invalid_peer_id_lookup":
    let peerId = PeerId.random().expect("could not generate peerId")
    check:
      mixNodes.findByPeerId(peerId).isErr()

  test "write and read mixnodeinfo":
    for i in 0 ..< count:
      let node = mixNodes[i]
      node.writeToFile(i).expect("File write error")
      let readNode = MixNodeInfo.readFromFile(i).expect("Read node error")

      check:
        readNode == node

  test "write and read mixpubinfo":
    for i in 0 ..< count:
      let mixPubInfo =
        mixNodes.getMixPubInfoByIndex(i).expect("couldnt obtain mixpubinfo")
      mixPubInfo.writeToFile(i).expect("File write error")
      let readNode = MixPubInfo.readFromFile(i).expect("File read error")

      check:
        mixPubInfo == readNode

  test "read nonexistent mixnodeinfo":
    check:
      MixNodeInfo.readFromFile(999).isErr()

  test "generate mix nodes with different ports":
    const count = 3
    let basePort = 5000
    let mixNodes =
      initializeMixNodes(count, basePort).expect("could not generate mix nodes")

    for i in 0 ..< count:
      let tcpPort = mixNodes[i].multiAddr.getPart(multiCodec("tcp")).value()
      let expectedPort = MultiAddress.init(fmt"/tcp/{basePort + i}").tryGet()
      check:
        tcpPort == expectedPort
