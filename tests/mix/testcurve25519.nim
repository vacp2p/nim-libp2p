{.used.}

import chronicles, results, unittest
import ../../libp2p/crypto/curve25519
import ../../libp2p/protocols/mix/curve25519

# Helper function for non-zero check
proc isNotZero(key: FieldElement): bool =
  for byte in key:
    if byte != 0:
      return true
  return false

suite "curve25519_tests":
  test "generate_key_pair":
    let keyPairResult = generateKeyPair()
    if keyPairResult.isErr:
      error "Generate key pair error", err = keyPairResult.error
      fail()
    let (privateKey, publicKey) = keyPairResult.get()

    if fieldElementToBytes(privateKey).len != FieldElementSize:
      error "Private key size must be 32 bytes"
      fail()

    if fieldElementToBytes(publicKey).len != FieldElementSize:
      error "Public key size must be 32 bytes"
      fail()

    if not privateKey.isNotZero():
      error "Private key is empty"
      fail()

    if not publicKey.isNotZero():
      error "Public key is empty"
      fail()

    let derivedPublicKeyResult = multiplyBasePointWithScalars(@[privateKey])
    if derivedPublicKeyResult.isErr:
      error "Multiply base point with scalar error", err = derivedPublicKeyResult.error
      fail()
    let derivedPublicKey = derivedPublicKeyResult.get()

    if publicKey != derivedPublicKey:
      error "Public keydoes not match derived key",
        publickey = publicKey, derivedkey = derivedPublicKey
      fail()

  test "commutativity":
    let x1Result = generateRandomFieldElement()
    if x1Result.isErr:
      error "Generate random field element error", err = x1Result.error
      fail()
    let x1 = x1Result.get()

    let x2Result = generateRandomFieldElement()
    if x2Result.isErr:
      error "Generate random field element error", err = x2Result.error
      fail()
    let x2 = x2Result.get()

    var res1Result = multiplyBasePointWithScalars(@[x1, x2])
    if res1Result.isErr:
      error "Multiply base point with scalar errors", err = res1Result.error
      fail()
    let res1 = res1Result.get()

    let
      intermediate = public(x2)
      res2 = multiplyPointWithScalars(intermediate, @[x1])

    if res1 != res2:
      error "Field element operations must be commutative", res1 = res1, res2 = res2
      fail()
