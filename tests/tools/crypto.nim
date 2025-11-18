# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import stew/byteutils
import ../../libp2p/[crypto/crypto, transports/wstransport, transports/tls/certificate]

type RngWrap = object
  rng: ref HmacDrbgContext

var rngVar: RngWrap

proc getRng(): ref HmacDrbgContext =
  # TODO if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil:
      rngVar.rng = newRng()
    rngVar.rng

template rng*(): ref HmacDrbgContext =
  getRng()

proc tlsCertGenerator*(
    kp: Opt[KeyPair] = Opt.none(KeyPair)
): (TLSPrivateKey, TLSCertificate) {.gcsafe, raises: [].} =
  try:
    let keyPair = kp.valueOr:
      KeyPair.random(PKScheme.RSA, rng()[]).get()
    let certX509 = generateX509(keyPair, encodingFormat = EncodingFormat.PEM)

    let secureKey = TLSPrivateKey.init(string.fromBytes(certX509.privateKey))
    let secureCert = TLSCertificate.init(string.fromBytes(certX509.certificate))

    (secureKey, secureCert)
  except TLSStreamProtocolError, TLSCertificateError:
    raiseAssert "should not happen"
