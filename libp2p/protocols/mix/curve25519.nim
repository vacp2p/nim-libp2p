import results
import bearssl/rand
import ../../crypto/curve25519

const FieldElementSize* = Curve25519KeySize

type FieldElement* = Curve25519Key

proc bytesToFieldElement*(bytes: openArray[byte]): Result[FieldElement, string] =
  ## Convert bytes to FieldElement
  if bytes.len != FieldElementSize:
    return err("Field element size must be 32 bytes")
  ok(intoCurve25519Key(bytes))

proc fieldElementToBytes*(fe: FieldElement): seq[byte] =
  ## Convert FieldElement to bytes
  fe.getBytes()

# Generate a random FieldElement
proc generateRandomFieldElement*(): Result[FieldElement, string] =
  let rng = HmacDrbgContext.new()
  if rng.isNil:
    return err("Failed to create HmacDrbgContext with system randomness")
  ok(Curve25519Key.random(rng[]))

# Generate a key pair (private key and public key are both FieldElements)
proc generateKeyPair*(): Result[tuple[privateKey, publicKey: FieldElement], string] =
  let privateKey = generateRandomFieldElement().valueOr:
    return err("Error in private key generation: " & error)

  let publicKey = public(privateKey)
  ok((privateKey, publicKey))

proc multiplyPointWithScalars*(
    point: FieldElement, scalars: openArray[FieldElement]
): FieldElement =
  ## Multiply a given Curve25519 point with a set of scalars
  var res = point
  for scalar in scalars:
    Curve25519.mul(res, scalar)
  res

proc multiplyBasePointWithScalars*(
    scalars: openArray[FieldElement]
): Result[FieldElement, string] =
  ## Multiply the Curve25519 base point with a set of scalars
  if scalars.len <= 0:
    return err("Atleast one scalar must be provided")
  var res: FieldElement = public(scalars[0]) # Use the predefined base point
  for i in 1 ..< scalars.len:
    Curve25519.mul(res, scalars[i]) # Multiply with each scalar
  ok(res)
