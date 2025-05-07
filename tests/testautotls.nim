{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[strutils, sequtils, tables]
import chronos
import
  ../libp2p/[
    stream/connection,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    autotls/autotls,
    autotls/acme,
  ]

import ./helpers

suite "AutoTLS":
  suite "ACME communication":
    asyncTest "test ACME challange request":
      let rng = newRng()
      let accountKey = KeyPair.random(PKScheme.RSA, rng[]).get()
      let acc = await ACMEAccount.new(accountKey)
      await acc.register()
      # account was registered (kid set)
      check acc.kid.isSome
      # challenge requested
      let (dns01Challenge, finalizeURL, orderURL) =
        await acc.requestChallenge(@["some.dummy.domain.com"])
      check dns01Challenge.isNil == false
      check finalizeURL.len > 0
      check orderURL.len > 0

        # asyncTest "test ACME challenge request":
        #   await autotlsMgr.start()

        # suite "AutoTLS broker handling":
        #   asyncSetup:
        #     rng = newRng()
        #     autotlsMgr = AutoTLSManager.new()

        #   asyncTest "test ACME account registration":
