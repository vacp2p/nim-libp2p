import results
import bearssl/rand
import ../../crypto/curve25519

const FieldElementSize* = Curve25519KeySize

type FieldElement* = Curve25519Key

# Convert bytes to FieldElement
proc bytesToFieldElement*(bytes: openArray[byte]): Result[FieldElement, string] =
  if bytes.len != FieldElementSize:
    return err("Field element size must be 32 bytes")
  ok(intoCurve25519Key(bytes))

# Convert FieldElement to bytes
proc fieldElementToBytes*(fe: FieldElement): seq[byte] =
  fe.getBytes()

# Generate a random FieldElement
proc generateRandomFieldElement*(): Result[FieldElement, string] =
  let rng = HmacDrbgContext.new()
  if rng.isNil:
    return err("Failed to creat HmacDrbgContext with system randomness")
  ok(Curve25519Key.random(rng[]))

# Generate a key pair (private key and public key are both FieldElements)
proc generateKeyPair*(): Result[tuple[privateKey, publicKey: FieldElement], string] =
  let privateKey = generateRandomFieldElement().valueOr:
    return err("Error in private key generation: " & error)

  let publicKey = public(privateKey)
  ok((privateKey, publicKey))

# Multiply a given Curve25519 point with a set of scalars
proc multiplyPointWithScalars*(
    point: FieldElement, scalars: openArray[FieldElement]
): FieldElement =
  var res = point
  for scalar in scalars:
    Curve25519.mul(res, scalar)
  res

# Multiply the Curve25519 base point with a set of scalars
proc multiplyBasePointWithScalars*(
    scalars: openArray[FieldElement]
): Result[FieldElement, string] =
  if scalars.len <= 0:
    return err("Atleast one scalar must be provided")
  var res: FieldElement = public(scalars[0]) # Use the predefined base point
  for i in 1 ..< scalars.len:
    Curve25519.mul(res, scalars[i]) # Multiply with each scalar
  ok(res)
