when defined(libp2p_autotls_support):
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
      acmeClient:
        ACMEClient.new(api = ACMEApi.new(acmeServerURL = config.acmeServerURL)),
      brokerClient: PeerIDAuthClient.new(),
      bearer: Opt.none(BearerToken),
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
