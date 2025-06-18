# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, results, bio

import ./api, ./utils
import ../../crypto/crypto
import ../../crypto/rsa

type KeyAuthorization* = string

type ACMEClient* = object
  api: ACMEApi
  key*: KeyPair
  kid*: Kid

proc new*(
    T: typedesc[ACMEClient],
    api: Opt[ACMEApi] = Opt.none(ACMEApi),
    key: Opt[KeyPair] = Opt.none(KeyPair),
    rng: ref HmacDrbgContext = newRng(),
    acmeServerURL: string = LetsEncryptURL,
): Future[T] {.async: (raises: [ACMEError, CancelledError]).} =
  let api = api.valueOr:
    await ACMEApi.new()
  let key = key.valueOr:
    KeyPair.random(PKScheme.RSA, rng[]).get()
  let registerResponse = await api.requestRegister(key)
  T(api: api, key: key, kid: registerResponse.kid)

proc genKeyAuthorization*(self: ACMEClient, token: string): KeyAuthorization =
  base64UrlEncode(@(sha256.digest((token & "." & thumbprint(self.key)).toByteSeq).data))

proc close*(self: ACMEClient): Future[void] {.async: (raises: [CancelledError]).} =
  await self.api.close()
