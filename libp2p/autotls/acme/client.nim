# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, results

import ./api

type KeyAuthorization* = string

type ACMEClient* = object
  api: ACMEApi
  key*: KeyPair
  kid*: Kid

proc new*(
    T: typedesc[ACMEClient],
    key: Opt[KeyPair] = Opt.none(KeyPair),
    acmeServerURL: string = LetsEncryptURL,
): Future[T] {.async: (raises: [ACMEError, CancelledError]).} =
  let api = await ACMEApi.new()
  let key = key.valueOr:
    KeyPair.random(PKScheme.RSA, self.rng[]).get()
  let kid = await api.requestRegister(key)
  T(api: api, key: key, kid: kid)

proc genKeyAuthorization*(self: ACMEClient, domains: seq[Domain]): KeyAuthorization =
  let dns01 = self.api.requestChallenge(domains, self.key, self.kid)
  base64UrlEncode(
    @(sha256.digest((dns01.token & "." & thumbprint(self.key)).toByteSeq).data)
  )
