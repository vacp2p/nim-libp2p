import results, sequtils
import ./[config, crypto, curve25519, serialization, tag_manager, utils]

# Define possible outcomes of processing a Sphinx packet
type ProcessingStatus* = enum
  Exit # Packet processed successfully at exit
  Intermediate # Packet processed successfully at intermediate node
  Duplicate # Packet was discarded due to duplicate tag
  InvalidMAC # Packet was discarded due to MAC verification failure

# Compute alpha, an ephemeral public value. Each mix node uses its private key and 
# alpha to derive a shared session key for that hop. 
# This session key is used to decrypt and process one layer of the packet.
proc computeAlpha(
    publicKeys: openArray[FieldElement]
): Result[(seq[byte], seq[seq[byte]]), string] =
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
      return err("Invalid public key " & $i)

    # Compute alpha, shared secret, and blinder
    if i == 0:
      alpha = multiplyBasePointWithScalars([blinders[i]]).valueOr:
        return err("Multiply base point with scalars error: " & error)

      alpha_0 = fieldElementToBytes(alpha)
    else:
      alpha = multiplyPointWithScalars(alpha, [blinders[i]])

    secret = multiplyPointWithScalars(publicKeys[i], blinders)
      # ToDo: Optimize point multiplication by multiplying scalars first

    let blinder = bytesToFieldElement(
      sha256_hash(fieldElementToBytes(alpha) & fieldElementToBytes(secret))
    ).valueOr:
      return err("Error in bytes to field element conversion: " & error)

    blinders.add(blinder)

    s[i] = fieldElementToBytes(secret)

  return ok((alpha_0, s))

# Helper function to derive key material
proc deriveKeyMaterial(keyName: string, s: seq[byte]): seq[byte] =
  let keyNameBytes = @(keyName.toOpenArrayByte(0, keyName.high))
  return keyNameBytes & s

# Function to compute filler strings
proc computeFillerStrings(s: seq[seq[byte]]): Result[seq[byte], string] =
  var filler: seq[byte] = @[] # Start with an empty filler string

  for i in 1 ..< s.len:
    # Derive AES key and IV
    let
      aes_key = kdf(deriveKeyMaterial("aes_key", s[i - 1]))
      iv = kdf(deriveKeyMaterial("iv", s[i - 1]))

    # Compute filler string
    let
      fillerLength = (t + 1) * k
      zeroPadding = newSeq[byte](fillerLength)

    filler = aes_ctr_start_index(
      aes_key, iv, filler & zeroPadding, (((t + 1) * (r - i)) + t + 2) * k
    ).valueOr:
      return err("Error in aes with start index: " & error)

  return ok(filler)

const paddingLength = (((t + 1) * (r - L)) + 1) * k

# Function to compute:
# Beta: The nested encrypted routing information. It encodes the next hop address, the forwarding delay, integrity check Gamma for the next hop, and the Beta for subsequent hops.
# Gamma: A message authentication code computed over Beta using the session key derived from Alpha. It ensures header integrity at each hop.
proc computeBetaGamma(
    s: seq[seq[byte]],
    hop: openArray[Hop],
    delay: openArray[seq[byte]],
    destHop: Hop,
    id: I,
): Result[tuple[beta: seq[byte], gamma: seq[byte]], string] =
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
      beta_aes_key = kdf(deriveKeyMaterial("aes_key", s[i]))
      mac_key = kdf(deriveKeyMaterial("mac_key", s[i]))
      beta_iv = kdf(deriveKeyMaterial("iv", s[i]))

    # Compute Beta and Gamma
    if i == sLen - 1:
      let destBytes = ?destHop.serialize()
      let destPadding = destBytes & delay[i] & @id & newSeq[byte](paddingLength)

      let aes = aes_ctr(beta_aes_key, beta_iv, destPadding).valueOr:
        return err("Error in aes: " & error)
      beta = aes & filler
    else:
      let routingInfo = RoutingInfo.init(
        hop[i + 1], delay[i], gamma, beta[0 .. (((r * (t + 1)) - t) * k) - 1]
      )

      let serializedRoutingInfo = routingInfo.serialize().valueOr:
        return err("Routing info serialization error: " & error)

      beta = aes_ctr(beta_aes_key, beta_iv, serializedRoutingInfo).valueOr:
        return err("Error in aes: " & error)

    gamma = toSeq(hmac(mac_key, beta))

  return ok((beta: beta, gamma: gamma))

# Function to compute deltas
proc computeDelta(s: seq[seq[byte]], msg: Message): Result[seq[byte], string] =
  let sLen = s.len
  var delta: seq[byte]

  for i in countdown(sLen - 1, 0):
    # Derive AES key and IV
    let
      delta_aes_key = kdf(deriveKeyMaterial("delta_aes_key", s[i]))
      delta_iv = kdf(deriveKeyMaterial("delta_iv", s[i]))

    # Compute Delta
    if i == sLen - 1:
      let serializedMsg = msg.serialize().valueOr:
        return err("Message serialization error: " & error)

      delta = aes_ctr(delta_aes_key, delta_iv, serializedMsg).valueOr:
        return err("Error in aes: " & error)
    else:
      delta = aes_ctr(delta_aes_key, delta_iv, delta).valueOr:
        return err("Error in aes: " & error)

  return ok(delta)

proc wrapInSphinxPacket*(
    msg: Message,
    publicKeys: openArray[FieldElement],
    delay: openArray[seq[byte]],
    hop: openArray[Hop],
    destHop: Hop,
): Result[seq[byte], string] =
  # Compute alpha and shared secrets
  let (alpha_0, s) = computeAlpha(publicKeys).valueOr:
    return err("Error in alpha generation: " & error)

  # Compute beta and gamma
  let (beta_0, gamma_0) = computeBetaGamma(s, hop, delay, destHop, default(I)).valueOr:
    return err("Error in beta and gamma generation: " & error)

  # Compute delta
  let delta_0 = computeDelta(s, msg).valueOr:
    return err("Error in delta generation: " & error)

  # Serialize sphinx packet
  let sphinxPacket = SphinxPacket.init(Header.init(alpha_0, beta_0, gamma_0), delta_0)

  let serialized = sphinxPacket.serialize().valueOr:
    return err("Sphinx packet serialization error: " & error)

  return ok(serialized)

type ProcessedSphinxPacket* = object
  case status*: ProcessingStatus
  of ProcessingStatus.Exit:
    destination*: Hop
    messageChunk*: seq[byte]
  of ProcessingStatus.Intermediate:
    nextHop*: Hop
    delayMs*: int
    serializedSphinxPacket*: seq[byte]
  else:
    discard

proc processSphinxPacket*(
    sphinxPacket: SphinxPacket, privateKey: FieldElement, tm: var TagManager
): Result[ProcessedSphinxPacket, string] =
  let
    (header, payload) = sphinxPacket.getSphinxPacket()
    (alpha, beta, gamma) = getHeader(header)

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
  let mac_key = kdf(deriveKeyMaterial("mac_key", sBytes))

  if not (toSeq(hmac(mac_key, beta)) == gamma):
    # If MAC not verified
    return ok(ProcessedSphinxPacket(status: InvalidMAC))

  # Store the tag as seen
  addTag(tm, s)

  # Derive AES key and IV
  let
    beta_aes_key = kdf(deriveKeyMaterial("aes_key", sBytes))
    beta_iv = kdf(deriveKeyMaterial("iv", sBytes))

    delta_aes_key = kdf(deriveKeyMaterial("delta_aes_key", sBytes))
    delta_iv = kdf(deriveKeyMaterial("delta_iv", sBytes))

  # Compute delta
  let delta_prime = aes_ctr(delta_aes_key, delta_iv, payload).valueOr:
    return err("Error in aes: " & error)

  # Compute B
  var zeroPadding = newSeq[byte]((t + 1) * k)

  let B = aes_ctr(beta_aes_key, beta_iv, beta & zeroPadding).valueOr:
    return err("Error in aes: " & error)

  # Check if B has the required prefix for the original message
  zeroPadding = newSeq[byte](paddingLength)

  if B[((t + 1) * k) .. ((t + 1) * k) + paddingLength - 1] == zeroPadding:
    let hop = Hop.deserialize(B[0 .. addrSize - 1]).valueOr:
      return err(error)

    if B[addrSize .. ((t + 1) * k) - 1] == newSeq[byte](k + 2):
      if delta_prime[0 .. (k - 1)] == newSeq[byte](k):
        let msg = Message.deserialize(delta_prime).valueOr:
          return err("Message deserialization error: " & error)
        let content = msg.getContent()
        return ok(
          ProcessedSphinxPacket(
            status: Exit, destination: hop, messageChunk: content[0 .. messageSize - 1]
          )
        )
      else:
        return err("delta_prime should be all zeros")
    elif B[0 .. (t * k) - 1] == newSeq[byte](t * k):
      # TODO: handle REPLY case
      discard
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

    let serializedSP = sphinxPkt.serialize().valueOr:
      return err("Sphinx packet serialization error: " & error)

    return ok(
      ProcessedSphinxPacket(
        status: Intermediate,
        nextHop: address,
        delayMs: (?bytesToUInt16(delay)).int,
        serializedSphinxPacket: serializedSP,
      )
    )
