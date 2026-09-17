# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronicles, json_serialization
import ../../../libp2p/utils/redact
import ../../../libp2p/crypto/[crypto, rsa, secp, ecnist, ed25519/ed25519]
import ../../tools/[unittest, crypto]

const
  marker = Redacted
  jsonMarker = Json.encode(Redacted)

suite "Representative secret key types are redacted":
  test "RSA private key is redacted via `$`, Chronicles and Json.encode":
    let kp = RsaPrivateKey.random(rng(), 2048).expect("random RSA key")
    check:
      $kp == marker
      Json.encode(kp) == jsonMarker
      chroniclesFormatItIMPL(kp) == marker

  test "Ed25519 private key and composite key pair are redacted":
    let pair = EdKeyPair.random(rng())
    check:
      $pair.seckey == marker
      $pair == marker
      Json.encode(pair) == jsonMarker
      chroniclesFormatItIMPL(pair.seckey) == marker

  test "secp256k1 key pair is redacted":
    let pair = SkKeyPair.random(rng())
    check:
      $pair == marker
      Json.encode(pair) == jsonMarker

  test "NIST EC key pair is redacted":
    let pair = EcKeyPair.random(Secp256r1, rng()).expect("random NIST key")
    check:
      $pair == marker
      Json.encode(pair) == jsonMarker
      chroniclesFormatItIMPL(pair) == marker

  test "generic libp2p PrivateKey and composite KeyPair are redacted":
    let priv = PrivateKey.random(PKScheme.Ed25519, rng()).get()
    let pair = KeyPair.random(PKScheme.Ed25519, rng()).get()
    check:
      $priv == marker
      Json.encode(priv) == jsonMarker
      chroniclesFormatItIMPL(priv) == marker and
        # composite (pub + priv) type must not leak raw-key content either
        $pair == marker
      Json.encode(pair) == jsonMarker
