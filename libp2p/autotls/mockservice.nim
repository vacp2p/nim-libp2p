import ./service, ./acme/client, ../peeridauth/client

import ../crypto/crypto, ../crypto/rsa, websock/websock

type MockAutotlsService* = ref object of AutotlsService
  mockedCert*: TLSCertificate
  mockedKey*: TLSPrivateKey

proc new*(
    T: typedesc[MockAutotlsService],
    rng: ref HmacDrbgContext = newRng(),
    config: AutotlsConfig = AutotlsConfig.new(),
): T =
  T(
    acmeClient: ACMEClient.new(api = ACMEApi.new(acmeServerURL = config.acmeServerURL)),
    brokerClient: PeerIDAuthClient.new(),
    bearer: Opt.none(BearerToken),
    cert: Opt.none(AutotlsCert),
    certReady: newAsyncEvent(),
    config: config,
    rng: rng,
  )

proc getTLSPrivkey*(self: MockAutotlsService): TLSPrivateKey =
  self.mockedKey

method getCertWhenReady*(
    self: MockAutotlsService
): Future[TLSCertificate] {.async: (raises: [AutoTLSError, CancelledError]).} =
  return self.mockedCert

method setup*(self: MockAutotlsService) {.base, async.} =
  discard
