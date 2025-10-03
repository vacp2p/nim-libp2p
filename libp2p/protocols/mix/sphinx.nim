import results, sequtils, stew/endians2
import ./[crypto, curve25519, serialization, tag_manager]
import ../../crypto/crypto
import ../../utils/sequninit

const PathLength* = 3 # Path length (L)
const PaddingLength = (((t + 1) * (r - PathLength)) + 1) * k

type ProcessingStatus* = enum
  Exit
  Intermediate
  Reply
  Duplicate
  InvalidMAC

proc computeAlpha(
    publicKeys: openArray[FieldElement]
): Result[(seq[byte], seq[seq[byte]]), string] =
  ## Compute alpha, an ephemeral public value. Each mix node uses its private key and 
  ## alpha to derive a shared session key for that hop. 
  ## This session key is used to decrypt and process one layer of the packet.

  if publicKeys.len == 0:
    return err("No public keys provided")

  var
    s: seq[seq[byte]] = newSeq[seq[byte]](publicKeys.len)
    alpha_0: seq[byte]
    alpha: FieldElement
    secret: FieldElement
    blinders: seq[FieldElement] = @[]

  let x = generateRandomFieldElement().valueOr:
    return err("Generate field element error: " & error)

  blinders.add(x)

  for i in 0 ..< publicKeys.len:
    if publicKeys[i].len != FieldElementSize:
      return err("Invalid public key size: " & $i)

    # Compute alpha, shared secret, and blinder
    if i == 0:
      alpha = multiplyBasePointWithScalars([blinders[i]]).valueOr:
        return err("Multiply base point with scalars error: " & error)

      alpha_0 = fieldElementToBytes(alpha)
    else:
      alpha = multiplyPointWithScalars(alpha, [blinders[i]])

    # TODO: Optimize point multiplication by multiplying scalars first
    secret = multiplyPointWithScalars(publicKeys[i], blinders)

    let blinder = bytesToFieldElement(
      sha256_hash(fieldElementToBytes(alpha) & fieldElementToBytes(secret))
    ).valueOr:
      return err("Error in bytes to field element conversion: " & error)

    blinders.add(blinder)

    s[i] = fieldElementToBytes(secret)

  return ok((alpha_0, s))

proc deriveKeyMaterial(keyName: string, s: seq[byte]): seq[byte] =
  @(keyName.toOpenArrayByte(0, keyName.high)) & s

proc computeFillerStrings(s: seq[seq[byte]]): Result[seq[byte], string] =
  var filler: seq[byte] = @[] # Start with an empty filler string

  for i in 1 ..< s.len:
    # Derive AES key and IV
    let
      aes_key = deriveKeyMaterial("aes_key", s[i - 1]).kdf()
      iv = deriveKeyMaterial("iv", s[i - 1]).kdf()

    # Compute filler string
    let
      fillerLength = (t + 1) * k
      zeroPadding = newSeq[byte](fillerLength)

    filler = aes_ctr_start_index(
      aes_key, iv, filler & zeroPadding, (((t + 1) * (r - i)) + t + 2) * k
    )

  return ok(filler)

proc computeBetaGamma(
    s: seq[seq[byte]],
    hops: openArray[Hop],
    delay: openArray[seq[byte]],
    destHop: Hop,
    id: SURBIdentifier,
): Result[tuple[beta: seq[byte], gamma: seq[byte]], string] =
  ## Calculates the following elements:
  ## - Beta: The nested encrypted routing information. It encodes the next hop address, the forwarding delay, integrity check Gamma for the next hop, and the Beta for subsequent hops.
  ## - Gamma: A message authentication code computed over Beta using the session key derived from Alpha. It ensures header integrity at each hop.
  let sLen = s.len
  var
    beta: seq[byte]
    gamma: seq[byte]

  # Compute filler strings
  let filler = computeFillerStrings(s).valueOr:
    return err("Error in filler generation: " & error)

  for i in countdown(sLen - 1, 0):
    # Derive AES key, MAC key, and IV
    let
      beta_aes_key = deriveKeyMaterial("aes_key", s[i]).kdf()
      mac_key = deriveKeyMaterial("mac_key", s[i]).kdf()
      beta_iv = deriveKeyMaterial("iv", s[i]).kdf()

    # Compute Beta and Gamma
    if i == sLen - 1:
      let destBytes = destHop.serialize()
      let destPadding = destBytes & delay[i] & @id & newSeq[byte](PaddingLength)

      let aes = aes_ctr(beta_aes_key, beta_iv, destPadding)

      beta = aes & filler
    else:
      let routingInfo = RoutingInfo.init(
        hops[i + 1], delay[i], gamma, beta[0 .. (((r * (t + 1)) - t) * k) - 1]
      )

      let serializedRoutingInfo = routingInfo.serialize()

      beta = aes_ctr(beta_aes_key, beta_iv, serializedRoutingInfo)

    gamma = hmac(mac_key, beta).toSeq()

  return ok((beta: beta, gamma: gamma))

proc computeDelta(s: seq[seq[byte]], msg: Message): Result[seq[byte], string] =
  let sLen = s.len
  var delta: seq[byte]

  for i in countdown(sLen - 1, 0):
    # Derive AES key and IV
    let
      delta_aes_key = deriveKeyMaterial("delta_aes_key", s[i]).kdf()
      delta_iv = deriveKeyMaterial("delta_iv", s[i]).kdf()

    # Compute Delta
    if i == sLen - 1:
      let serializedMsg = msg.serialize()
      delta = aes_ctr(delta_aes_key, delta_iv, serializedMsg)
    else:
      delta = aes_ctr(delta_aes_key, delta_iv, delta)

  return ok(delta)

proc createSURB*(
    publicKeys: openArray[FieldElement],
    delay: openArray[seq[byte]],
    hops: openArray[Hop],
    id: SURBIdentifier,
    rng: ref HmacDrbgContext = newRng(),
): Result[SURB, string] =
  if id == default(SURBIdentifier):
    return err("id should be initialized")

  # Compute alpha and shared secrets
  let (alpha_0, s) = computeAlpha(publicKeys).valueOr:
    return err("Error in alpha generation: " & error)

  # Compute beta and gamma
  let (beta_0, gamma_0) = computeBetaGamma(s, hops, delay, Hop(), id).valueOr:
    return err("Error in beta and gamma generation: " & error)

  # Generate key
  var key = newSeqUninit[byte](k)
  rng[].generate(key)

  return ok(
    SURB(
      hop: hops[0],
      header: Header.init(alpha_0, beta_0, gamma_0),
      secret: Opt.some(s),
      key: key,
    )
  )

proc useSURB*(surb: SURB, msg: Message): SphinxPacket =
  # Derive AES key and IV
  let
    delta_aes_key = deriveKeyMaterial("delta_aes_key", surb.key).kdf()
    delta_iv = deriveKeyMaterial("delta_iv", surb.key).kdf()

  # Compute Delta
  let serializedMsg = msg.serialize()
  let delta = aes_ctr(delta_aes_key, delta_iv, serializedMsg)

  return SphinxPacket.init(surb.header, delta)

proc processReply*(
    key: seq[byte], s: seq[seq[byte]], delta_prime: seq[byte]
): Result[seq[byte], string] =
  var delta = delta_prime[0 ..^ 1]

  var key_prime = key
  for i in 0 .. s.len:
    if i != 0:
      key_prime = s[i - 1]

    let
      delta_aes_key = deriveKeyMaterial("delta_aes_key", key_prime).kdf()
      delta_iv = deriveKeyMaterial("delta_iv", key_prime).kdf()

    delta = aes_ctr(delta_aes_key, delta_iv, delta)

  let deserializeMsg = Message.deserialize(delta).valueOr:
    return err("Message deserialization error: " & error)

  return ok(deserializeMsg)

proc wrapInSphinxPacket*(
    msg: Message,
    publicKeys: openArray[FieldElement],
    delay: openArray[seq[byte]],
    hop: openArray[Hop],
    destHop: Hop,
): Result[SphinxPacket, string] =
  # Compute alpha and shared secrets
  let (alpha_0, s) = computeAlpha(publicKeys).valueOr:
    return err("Error in alpha generation: " & error)

  # Compute beta and gamma
  let (beta_0, gamma_0) = computeBetaGamma(
    s, hop, delay, destHop, default(SURBIdentifier)
  ).valueOr:
    return err("Error in beta and gamma generation: " & error)

  # Compute delta
  let delta_0 = computeDelta(s, msg).valueOr:
    return err("Error in delta generation: " & error)

  # Serialize sphinx packet
  let sphinxPacket = SphinxPacket.init(Header.init(alpha_0, beta_0, gamma_0), delta_0)

  return ok(sphinxPacket)

type ProcessedSphinxPacket* = object
  case status*: ProcessingStatus
  of ProcessingStatus.Exit:
    destination*: Hop
    messageChunk*: seq[byte]
  of ProcessingStatus.Intermediate:
    nextHop*: Hop
    delayMs*: int
    serializedSphinxPacket*: seq[byte]
  of ProcessingStatus.Reply:
    id*: SURBIdentifier
    delta_prime*: seq[byte]
  else:
    discard

proc isZeros(data: seq[byte], startIdx: int, endIdx: int): bool =
  doAssert 0 <= startIdx and endIdx < data.len and startIdx <= endIdx
  for i in startIdx .. endIdx:
    if data[i] != 0:
      return false
  return true

template extractSurbId(data: seq[byte]): SURBIdentifier =
  const startIndex = t * k
  const endIndex = startIndex + SurbIdLen - 1
  doAssert data.len > startIndex and endIndex < data.len
  var id: SURBIdentifier
  copyMem(addr id[0], addr data[startIndex], SurbIdLen)
  id

proc processSphinxPacket*(
    sphinxPacket: SphinxPacket, privateKey: FieldElement, tm: var TagManager
): Result[ProcessedSphinxPacket, string] =
  let
    (header, payload) = sphinxPacket.get()
    (alpha, beta, gamma) = header.get()

  # Compute shared secret
  let alphaFE = bytesToFieldElement(alpha).valueOr:
    return err("Error in bytes to field element conversion: " & error)

  let
    s = multiplyPointWithScalars(alphaFE, [privateKey])
    sBytes = fieldElementToBytes(s)

  # Check if the tag has been seen
  if isTagSeen(tm, s):
    return ok(ProcessedSphinxPacket(status: Duplicate))

  # Compute MAC
  let mac_key = deriveKeyMaterial("mac_key", sBytes).kdf()

  if not (hmac(mac_key, beta).toSeq() == gamma):
    # If MAC not verified
    return ok(ProcessedSphinxPacket(status: InvalidMAC))

  # Store the tag as seen
  addTag(tm, s)

  # Derive AES key and IV
  let
    beta_aes_key = deriveKeyMaterial("aes_key", sBytes).kdf()
    beta_iv = deriveKeyMaterial("iv", sBytes).kdf()

    delta_aes_key = deriveKeyMaterial("delta_aes_key", sBytes).kdf()
    delta_iv = deriveKeyMaterial("delta_iv", sBytes).kdf()

  # Compute delta
  let delta_prime = aes_ctr(delta_aes_key, delta_iv, payload)

  # Compute B
  let zeroPadding = newSeq[byte]((t + 1) * k)
  let B = aes_ctr(beta_aes_key, beta_iv, beta & zeroPadding)

  # Check if B has the required prefix for the original message
  if B.isZeros((t + 1) * k, ((t + 1) * k) + PaddingLength - 1):
    let hop = Hop.deserialize(B[0 .. AddrSize - 1]).valueOr:
      return err(error)

    if B.isZeros(AddrSize, ((t + 1) * k) - 1):
      if delta_prime.isZeros(0, k - 1):
        let msg = Message.deserialize(delta_prime).valueOr:
          return err("Message deserialization error: " & error)
        return ok(
          ProcessedSphinxPacket(
            status: Exit, destination: hop, messageChunk: msg[0 .. MessageSize - 1]
          )
        )
      else:
        return err("delta_prime should be all zeros")
    elif B.isZeros(0, (t * k) - 1):
      return ok(
        ProcessedSphinxPacket(
          status: Reply, id: B.extractSurbId(), delta_prime: delta_prime
        )
      )
  else:
    # Extract routing information from B
    let routingInfo = RoutingInfo.deserialize(B).valueOr:
      return err("Routing info deserialization error: " & error)

    let (address, delay, gamma_prime, beta_prime) = routingInfo.getRoutingInfo()

    # Compute alpha
    let blinder = bytesToFieldElement(sha256_hash(alpha & sBytes)).valueOr:
      return err("Error in bytes to field element conversion: " & error)

    let alphaFE = bytesToFieldElement(alpha).valueOr:
      return err("Error in bytes to field element conversion: " & error)

    let alpha_prime = multiplyPointWithScalars(alphaFE, [blinder])

    # Serialize sphinx packet
    let sphinxPkt = SphinxPacket.init(
      Header.init(fieldElementToBytes(alpha_prime), beta_prime, gamma_prime),
      delta_prime,
    )

    return ok(
      ProcessedSphinxPacket(
        status: Intermediate,
        nextHop: address,
        delayMs: uint16.fromBytes(delay).int,
        serializedSphinxPacket: sphinxPkt.serialize(),
      )
    )
