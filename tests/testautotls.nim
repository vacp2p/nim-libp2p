{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

# import std/[strformat, net] # uncomment after re-enabling AutoTLSManager
import chronos
import chronos/apps/http/httpclient
import
  ../libp2p/
    [
      stream/connection,
      upgrademngrs/upgrade,
      autotls/acme/api,
      autotls/acme/utils,
      wire,
    ]

import ./helpers

suite "AutoTLS":
  var api {.threadvar.}: ACMEApi
  var key {.threadvar.}: KeyPair

  asyncTeardown:
    await api.close()
    checkTrackers()

  asyncSetup:
    api = await ACMEApi.new(acmeServerURL = LetsEncryptURLStaging)
    key = KeyPair.random(PKScheme.RSA, newRng()[]).get()

  asyncTest "test request challenge":
    let registerResponse = await api.requestRegister(key)
    # account was registered (kid set)
    check registerResponse.kid != ""
    if registerResponse.kid == "":
      raiseAssert "unable to register acme account"

    # challenge requested
    let challenge =
      await api.requestChallenge(@["some.dummy.domain.com"], key, registerResponse.kid)
    check challenge.finalizeURL.len() > 0
    check challenge.orderURL.len() > 0

    check challenge.dns01.url.len() > 0
    check challenge.dns01.`type`.len() > 0
    check challenge.dns01.status.len() > 0
    check challenge.dns01.token.len() > 0

  asyncTest "test register with unsupported keys":
    let unsupportedSchemes = [PKScheme.Ed25519, PKScheme.Secp256k1, PKScheme.ECDSA]
    for scheme in unsupportedSchemes:
      let unsupportedKey = KeyPair.random(scheme, newRng()[]).get()
      expect(ACMEError):
        discard await api.requestRegister(unsupportedKey)

  asyncTest "test request challenge with invalid kid":
    expect(ACMEError):
      discard await api.requestChallenge(@["domain.com"], key, "invalid_kid_here")
