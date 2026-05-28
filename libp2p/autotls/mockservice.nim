# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import ./service, ./acme/client, ./broker

import ../crypto/crypto, ../crypto/rsa, websock/websock

type MockAutotlsService* = ref object of AutotlsService
  mockedCert*: TLSCertificate
  mockedKey*: TLSPrivateKey

proc new*(
    T: typedesc[MockAutotlsService],
    rng: Rng,
    config: AutotlsConfig = AutotlsConfig.new(),
): T =
  T(
    acmeClient:
      ACMEClient.new(rng = rng, api = ACMEApi.new(acmeServerURL = config.acmeServerURL)),
    broker: AutotlsBroker.new(rng, brokerURL = config.brokerURL),
    cert: Opt.none(AutotlsCert),
    certReady: newAsyncEvent(),
    running: newAsyncEvent(),
    config: config,
    rng: rng,
  )

method getCertWhenReady*(
    self: MockAutotlsService
): Future[AutotlsCert] {.async: (raises: [AutoTLSError, CancelledError]).} =
  AutotlsCert.new(self.mockedCert, self.mockedKey, Moment.now)

method setup*(self: MockAutotlsService) {.base, async.} =
  self.running.fire()
