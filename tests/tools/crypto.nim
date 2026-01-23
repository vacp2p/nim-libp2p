# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos/streams/tlsstream, stew/byteutils
import ../../libp2p/[crypto/crypto, transports/tls/certificate]

var rngSingleton {.threadvar.}: ref HmacDrbgContext
rngSingleton = newRng()

proc getRng(): ref HmacDrbgContext =
  rngSingleton

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
