import os, results, strformat, sugar, sequtils
import std/streams
import ../../crypto/[crypto, curve25519, secp]
import ../../[multiaddress, multicodec, peerid, peerinfo]
import ./[serialization, curve25519, multiaddr]

const MixNodeInfoSize* =
  AddrSize + (2 * FieldElementSize) + (SkRawPublicKeySize + SkRawPrivateKeySize)
const MixPubInfoSize* = AddrSize + FieldElementSize + SkRawPublicKeySize

type MixNodeInfo* = object
  peerId*: PeerId
  multiAddr*: MultiAddress
  mixPubKey*: FieldElement
  mixPrivKey*: FieldElement
  libp2pPubKey*: SkPublicKey
  libp2pPrivKey*: SkPrivateKey

proc initMixNodeInfo*(
    peerId: PeerId,
    multiAddr: MultiAddress,
    mixPubKey, mixPrivKey: FieldElement,
    libp2pPubKey: SkPublicKey,
    libp2pPrivKey: SkPrivateKey,
): MixNodeInfo =
  MixNodeInfo(
    peerId: peerId,
    multiAddr: multiAddr,
    mixPubKey: mixPubKey,
    mixPrivKey: mixPrivKey,
    libp2pPubKey: libp2pPubKey,
    libp2pPrivKey: libp2pPrivKey,
  )

proc get*(
    info: MixNodeInfo
): (PeerId, MultiAddress, FieldElement, FieldElement, SkPublicKey, SkPrivateKey) =
  (
    info.peerId, info.multiAddr, info.mixPubKey, info.mixPrivKey, info.libp2pPubKey,
    info.libp2pPrivKey,
  )

proc serialize*(nodeInfo: MixNodeInfo): Result[seq[byte], string] =
  let addrBytes = multiAddrToBytes(nodeInfo.peerId, nodeInfo.multiAddr).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)

  let
    mixPubKeyBytes = fieldElementToBytes(nodeInfo.mixPubKey)
    mixPrivKeyBytes = fieldElementToBytes(nodeInfo.mixPrivKey)
    libp2pPubKeyBytes = nodeInfo.libp2pPubKey.getBytes()
    libp2pPrivKeyBytes = nodeInfo.libp2pPrivKey.getBytes()

  return ok(
    addrBytes & mixPubKeyBytes & mixPrivKeyBytes & libp2pPubKeyBytes & libp2pPrivKeyBytes
  )

proc deserialize*(T: typedesc[MixNodeInfo], data: openArray[byte]): Result[T, string] =
  if len(data) != MixNodeInfoSize:
    return
      err("Serialized Mix node info must be exactly " & $MixNodeInfoSize & " bytes")

  let (peerId, multiAddr) = bytesToMultiAddr(data[0 .. AddrSize - 1]).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)

  let mixPubKey = bytesToFieldElement(
    data[AddrSize .. (AddrSize + FieldElementSize - 1)]
  ).valueOr:
    return err("Mix public key deserialize error: " & error)

  let mixPrivKey = bytesToFieldElement(
    data[(AddrSize + FieldElementSize) .. (AddrSize + (2 * FieldElementSize) - 1)]
  ).valueOr:
    return err("Mix private key deserialize error: " & error)

  let libp2pPubKey = SkPublicKey.init(
    data[
      AddrSize + (2 * FieldElementSize) ..
        AddrSize + (2 * FieldElementSize) + SkRawPublicKeySize - 1
    ]
  ).valueOr:
    return err("Failed to initialize libp2p public key")

  let libp2pPrivKey = SkPrivateKey.init(
    data[AddrSize + (2 * FieldElementSize) + SkRawPublicKeySize ..^ 1]
  ).valueOr:
    return err("Failed to initialize libp2p private key")

  ok(
    T(
      peerId: peerId,
      multiAddr: multiAddr,
      mixPubKey: mixPubKey,
      mixPrivKey: mixPrivKey,
      libp2pPubKey: libp2pPubKey,
      libp2pPrivKey: libp2pPrivKey,
    )
  )

proc writeToFile*(
    node: MixNodeInfo, index: int, nodeInfoFolderPath: string = "./nodeInfo"
): Result[void, string] =
  if not dirExists(nodeInfoFolderPath):
    createDir(nodeInfoFolderPath)
  let filename = nodeInfoFolderPath / fmt"mixNode_{index}"
  var file = newFileStream(filename, fmWrite)
  if file == nil:
    return err("Failed to create file stream for " & filename)
  defer:
    file.close()

  let serializedData = node.serialize().valueOr:
    return err("Failed to serialize mix node info: " & error)

  file.writeData(addr serializedData[0], serializedData.len)
  return ok()

proc readFromFile*(
    T: typedesc[MixNodeInfo], index: int, nodeInfoFolderPath: string = "./nodeInfo"
): Result[T, string] =
  let filename = nodeInfoFolderPath / fmt"mixNode_{index}"
  if not fileExists(filename):
    return err("File does not exist")
  var file = newFileStream(filename, fmRead)
  if file == nil:
    return err(
      "Failed to open file: " & filename &
        ". Check permissions or if the path is correct."
    )
  defer:
    file.close()

  let data = ?file.readAll().catch().mapErr(x => "File read error: " & x.msg)
  if data.len != MixNodeInfoSize:
    return err(
      "Invalid data size for MixNodeInfo: expected " & $MixNodeInfoSize &
        " bytes, but got " & $(data.len) & " bytes."
    )
  let dMixNodeInfo = MixNodeInfo.deserialize(cast[seq[byte]](data)).valueOr:
    return err("Mix node info deserialize error: " & error)
  return ok(dMixNodeInfo)

proc deleteNodeInfoFolder*(nodeInfoFolderPath: string = "./nodeInfo") =
  ## Deletes the folder that stores serialized mix node info files
  ## along with all its contents, if the folder exists.  
  if dirExists(nodeInfoFolderPath):
    removeDir(nodeInfoFolderPath)

type MixPubInfo* = object
  peerId*: PeerId
  multiAddr*: MultiAddress
  mixPubKey*: FieldElement
  libp2pPubKey*: SkPublicKey

proc init*(
    T: typedesc[MixPubInfo],
    peerId: PeerId,
    multiAddr: MultiAddress,
    mixPubKey: FieldElement,
    libp2pPubKey: SkPublicKey,
): T =
  T(
    peerId: PeerId,
    multiAddr: multiAddr,
    mixPubKey: mixPubKey,
    libp2pPubKey: libp2pPubKey,
  )

proc get*(info: MixPubInfo): (PeerId, MultiAddress, FieldElement, SkPublicKey) =
  (info.peerId, info.multiAddr, info.mixPubKey, info.libp2pPubKey)

proc serialize*(nodeInfo: MixPubInfo): Result[seq[byte], string] =
  let addrBytes = multiAddrToBytes(nodeInfo.peerId, nodeInfo.multiAddr).valueOr:
    return err("Error in multiaddress conversion to bytes: " & error)

  let
    mixPubKeyBytes = fieldElementToBytes(nodeInfo.mixPubKey)
    libp2pPubKeyBytes = nodeInfo.libp2pPubKey.getBytes()

  return ok(addrBytes & mixPubKeyBytes & libp2pPubKeyBytes)

proc deserialize*(T: typedesc[MixPubInfo], data: openArray[byte]): Result[T, string] =
  if len(data) != MixPubInfoSize:
    return
      err("Serialized mix public info must be exactly " & $MixPubInfoSize & " bytes")

  let (peerId, multiAddr) = bytesToMultiAddr(data[0 .. AddrSize - 1]).valueOr:
    return err("Error in bytes to multiaddress conversion: " & error)

  let mixPubKey = bytesToFieldElement(
    data[AddrSize .. (AddrSize + FieldElementSize - 1)]
  ).valueOr:
    return err("Mix public key deserialize error: " & error)

  let libp2pPubKey = SkPublicKey.init(data[(AddrSize + FieldElementSize) ..^ 1]).valueOr:
    return err("Failed to initialize libp2p public key: ")

  ok(
    MixPubInfo(
      peerId: peerId,
      multiAddr: multiAddr,
      mixPubKey: mixPubKey,
      libp2pPubKey: libp2pPubKey,
    )
  )

proc writeToFile*(
    node: MixPubInfo, index: int, pubInfoFolderPath: string = "./pubInfo"
): Result[void, string] =
  if not dirExists(pubInfoFolderPath):
    createDir(pubInfoFolderPath)
  let filename = pubInfoFolderPath / fmt"mixNode_{index}"
  var file = newFileStream(filename, fmWrite)
  if file == nil:
    return err("Failed to create file stream for " & filename)
  defer:
    file.close()

  let serializedData = node.serialize().valueOr:
    return err("Failed to serialize mix pub info: " & error)

  file.writeData(unsafeAddr serializedData[0], serializedData.len)
  return ok()

proc readFromFile*(
    T: typedesc[MixPubInfo], index: int, pubInfoFolderPath: string = "./pubInfo"
): Result[T, string] =
  let filename = pubInfoFolderPath / fmt"mixNode_{index}"
  if not fileExists(filename):
    return err("File does not exist")
  var file = newFileStream(filename, fmRead)
  if file == nil:
    return err(
      "Failed to open file: " & filename &
        ". Check permissions or if the path is correct."
    )
  defer:
    file.close()
  let data = ?file.readAll().catch().mapErr(x => "File read error: " & x.msg)
  if data.len != MixPubInfoSize:
    return err(
      "Invalid data size for MixNodeInfo: expected " & $MixNodeInfoSize &
        " bytes, but got " & $(data.len) & " bytes."
    )
  let dMixPubInfo = MixPubInfo.deserialize(cast[seq[byte]](data)).valueOr:
    return err("Mix pub info deserialize error: " & error)
  return ok(dMixPubInfo)

proc deletePubInfoFolder*(pubInfoFolderPath: string = "./pubInfo") =
  ## Deletes the folder containing serialized public mix node info
  ## and all files inside it, if the folder exists.  
  if dirExists(pubInfoFolderPath):
    removeDir(pubInfoFolderPath)

type MixNodes* = seq[MixNodeInfo]

proc getMixPubInfoByIndex*(self: MixNodes, index: int): Result[MixPubInfo, string] =
  if index < 0 or index >= self.len:
    return err("Index must be between 0 and " & $(self.len))
  ok(
    MixPubInfo(
      peerId: self[index].peerId,
      multiAddr: self[index].multiAddr,
      mixPubKey: self[index].mixPubKey,
      libp2pPubKey: self[index].libp2pPubKey,
    )
  )

proc generateMixNodes(
    count: int, basePort: int = 4242, rng: ref HmacDrbgContext = newRng()
): Result[MixNodes, string] =
  var nodes = newSeq[MixNodeInfo](count)
  for i in 0 ..< count:
    let keyPairResult = generateKeyPair()
    if keyPairResult.isErr:
      return err("Generate key pair error: " & $keyPairResult.error)
    let (mixPrivKey, mixPubKey) = keyPairResult.get()

    let
      rng = newRng()
      keyPair = SkKeyPair.random(rng[])
      pubKeyProto = PublicKey(scheme: Secp256k1, skkey: keyPair.pubkey)
      peerId = PeerId.init(pubKeyProto).get()
      multiAddr =
        ?MultiAddress.init(fmt"/ip4/0.0.0.0/tcp/{basePort + i}").tryGet().catch().mapErr(
          x => x.msg
        )

    nodes[i] = MixNodeInfo(
      peerId: peerId,
      multiAddr: multiAddr,
      mixPubKey: mixPubKey,
      mixPrivKey: mixPrivKey,
      libp2pPubKey: keyPair.pubkey,
      libp2pPrivKey: keyPair.seckey,
    )

  ok(nodes)

proc initializeMixNodes*(count: int, basePort: int = 4242): Result[MixNodes, string] =
  ## Creates and initializes a set of mix nodes 
  let mixNodes = generateMixNodes(count, basePort).valueOr:
    return err("Mix node initialization error: " & error)
  return ok(mixNodes)

proc findByPeerId*(self: MixNodes, peerId: PeerId): Result[MixNodeInfo, string] =
  let filteredNodes = self.filterIt(it.peerId == peerId)
  if filteredNodes.len != 0:
    return ok(filteredNodes[0])
  return err("No node with peer id: " & $peerId)

proc initMixMultiAddrByIndex*(
    self: var MixNodes, index: int, peerId: PeerId, multiAddr: MultiAddress
): Result[void, string] =
  if index < 0 or index >= self.len:
    return err("Index must be between 0 and " & $(self.len))
  self[index].multiAddr = multiAddr
  self[index].peerId = peerId
  ok()
