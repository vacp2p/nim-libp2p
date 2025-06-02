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
import ../libp2p/[stream/connection, upgrademngrs/upgrade, autotls/acme/api, wire]

import ./helpers

suite "AutoTLS":
  teardown:
    checkTrackers()

  asyncTest "test ACME":
    let api = await ACMEApi.new(acmeServerURL = LetsEncryptURLStaging)
    defer:
      await api.session.closeWait()
    let key = KeyPair.random(PKScheme.RSA, newRng()[]).get()
    let registerResponse = await api.acmeRegister(key)
    # account was registered (kid set)
    check registerResponse.kid != ""

    # challenge requested
    # let (dns01Challenge, finalizeURL, orderURL) =
    #   await acc.requestChallenge(@["some.dummy.domain.com"])
    # check dns01Challenge.isNil == false
    # check finalizeURL.len > 0
    # check orderURL.len > 0
    # await noCancel(acc.session.closeWait())
