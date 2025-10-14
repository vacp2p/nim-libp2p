# Nim-LibP2P
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import strutils
import results
import times
import stew/byteutils
import chronicles
import ../../crypto/crypto
import ../../errors
import ./certificate_ffi
import ../../../libp2p/peerid
import ../../utils/sequninit

logScope:
  topics = "libp2p tls certificate"

# Exception types for TLS certificate errors
type
  TLSCertificateError* = object of LPError
  KeyGenerationError* = object of TLSCertificateError
  CertificateCreationError* = object of TLSCertificateError
  CertificatePubKeySerializationError* = object of TLSCertificateError
  CertificateParsingError* = object of TLSCertificateError
  IdentityPubKeySerializationError* = object of TLSCertificateError
  IdentitySigningError* = object of TLSCertificateError

# Define the P2pExtension and P2pCertificate types
type
  P2pExtension* = object
    publicKey*: seq[byte]
    signature*: seq[byte]

  P2pCertificate* = object
    extension*: P2pExtension
    pubKeyDer: seq[byte]
    validFrom: Time
    validTo: Time

  CertificateX509* = object
    certificate*: seq[byte]
      # Complete ASN.1 DER content (certificate, signature algorithm and signature).
    privateKey*: seq[byte] # Private key used to sign certificate

type EncodingFormat* = enum
  DER
  PEM

proc cert_format_t(self: EncodingFormat): cert_format_t =
  if self == EncodingFormat.DER: CERT_FORMAT_DER else: CERT_FORMAT_PEM

func publicKey*(cert: P2pCertificate): PublicKey =
  return PublicKey.init(cert.extension.publicKey).get()

func peerId*(cert: P2pCertificate): PeerId =
  return PeerId.init(cert.publicKey()).tryGet()

func makeSignatureMessage(pubKey: seq[byte]): seq[byte] {.inline.} =
  ## Creates message used for certificate signature.
  ##
  let P2P_SIGNING_PREFIX = "libp2p-tls-handshake:".toBytes()
  let prefixLen = P2P_SIGNING_PREFIX.len.int
  let msg = newSeqUninit[byte](prefixLen + pubKey.len)
  copyMem(msg[0].unsafeAddr, P2P_SIGNING_PREFIX[0].unsafeAddr, prefixLen)
  copyMem(msg[prefixLen].unsafeAddr, pubKey[0].unsafeAddr, pubKey.len.int)

  return msg

func makeIssuerDN(identityKeyPair: KeyPair): string {.inline.} =
  let issuerDN =
    try:
      $(PeerId.init(identityKeyPair.pubkey).tryGet())
    except LPError:
      raiseAssert "pubkey must be set"
  return issuerDN

proc makeASN1Time(time: Time): string {.inline.} =
  let str =
    try:
      let f = initTimeFormat("yyyyMMddhhmmss")
      format(time.utc(), f)
    except TimeFormatParseError as e:
      raiseAssert "time format is const and checked with test: " & e.msg

  return str & "Z"

proc makeExtValues(
    identityKeypair: KeyPair, certKey: CertificateKey
): tuple[signature: seq[byte], pubkey: seq[byte]] {.
    raises: [
      CertificatePubKeySerializationError, IdentitySigningError,
      IdentityPubKeySerializationError,
    ]
.} =
  ## Creates the buffers to be used for writing the libp2p extension
  ##
  ## Parameters:
  ## - `identityKeypair`: The peer's identity key pair.
  ## - `certificateKey`: The key used for the certificate.
  ##
  ## Returns:
  ## A sequence of bytes representing the libp2p extension.
  ##
  ## Raises:
  ## - `IdentitySigningError` if signing the message fails.
  ## - `CertificatePubKeySerializationError` if serialization of certificate public key fails
  ## - `IdentityPubKeySerializationError` if serialization of identity public key fails.

  let certificatePubKeyDer = cert_serialize_pubk(certKey, DER.cert_format_t()).valueOr:
    raise newException(
      CertificatePubKeySerializationError,
      "Failed to serialize the certificate pubkey: " & $error,
    )

  let msg = makeSignatureMessage(certificatePubKeyDer)

  # Sign the message with the Identity Key
  let signature = identityKeypair.seckey.sign(msg).valueOr:
    raise newException(
      IdentitySigningError,
      "Failed to sign the message with the identity key: " & $error,
    )

  # Get the public key bytes
  let pubKeyBytes = identityKeypair.pubkey.getBytes().valueOr:
    raise newException(
      IdentityPubKeySerializationError,
      "Failed to get identity public key bytes: " & $error,
    )

  return (signature.data, pubKeyBytes)

proc generateX509*(
    identityKeyPair: KeyPair,
    validFrom: Time = fromUnix(157813200),
    validTo: Time = fromUnix(67090165200),
    encodingFormat: EncodingFormat = EncodingFormat.DER,
): CertificateX509 {.
    raises: [
      KeyGenerationError, IdentitySigningError, IdentityPubKeySerializationError,
      CertificateCreationError, CertificatePubKeySerializationError,
    ]
.} =
  ## Generates a self-signed X.509 certificate with the libp2p extension.
  ##
  ## Parameters:
  ## - `identityKeyPair`: The peer's identity key pair.
  ## - `encodingFormat`: The encoding format of generated certificate.
  ##
  ## Returns:
  ## A tuple containing:
  ## - `raw` - The certificate content (encoded using encodingFormat).
  ## - `privateKey` - The private key.
  ##
  ## Raises:
  ## - `KeyGenerationError` if key generation fails.
  ## - `CertificateCreationError` if certificate creation fails.

  var certKey = cert_generate_key().valueOr:
    raise
      newException(KeyGenerationError, "Failed to generate certificate key: " & $error)

  let issuerDN = makeIssuerDN(identityKeyPair)
  let libp2pExtension = makeExtValues(identityKeyPair, certKey)
  let validFromAsn1 = makeASN1Time(validFrom)
  let validToAsn1 = makeASN1Time(validTo)

  let certificate = cert_generate(
    certKey, libp2pExtension.signature, libp2pExtension.pubkey, issuerDN,
    validFromAsn1.cstring, validToAsn1.cstring, encodingFormat.cert_format_t,
  ).valueOr:
    raise newException(
      CertificateCreationError, "Failed to generate certificate: " & $error
    )

  let privKDer = cert_serialize_privk(certKey, encodingFormat.cert_format_t).valueOr:
    raise newException(KeyGenerationError, "Failed to serialize privK: " & $error)

  return CertificateX509(certificate: certificate, privateKey: privKDer)

proc parseCertTime*(certTime: string): Time {.raises: [TimeParseError].} =
  var timeNoZone = certTime[0 ..^ 5] # removes GMT part
  # days with 1 digit have additional space -> strip it
  timeNoZone = timeNoZone.replace("  ", " ")

  const certTimeFormat = "MMM d hh:mm:ss yyyy"
  const f = initTimeFormat(certTimeFormat)
  return parse(timeNoZone, f, utc()).toTime()

proc parse*(
    certificateDer: seq[byte]
): P2pCertificate {.raises: [CertificateParsingError].} =
  ## Parses a DER-encoded certificate and extracts the P2pCertificate.
  ##
  ## Parameters:
  ## - `certificateDer`: The DER-encoded certificate bytes.
  ##
  ## Returns:
  ## A `P2pCertificate` object containing the certificate and its libp2p extension.
  ##
  ## Raises:
  ## - `CertificateParsingError` if certificate parsing fails.

  let certParsed = cert_parse(certificateDer, DER.cert_format_t()).valueOr:
    raise
      newException(CertificateParsingError, "Failed to parse certificate: " & $error)

  var validFrom, validTo: Time
  try:
    validFrom = parseCertTime($certParsed.validFrom)
    validTo = parseCertTime($certParsed.validTo)
  except TimeParseError as e:
    raise newException(
      CertificateParsingError, "Failed to parse certificate validity time: " & $e.msg, e
    )

  P2pCertificate(
    extension:
      P2pExtension(signature: certParsed.signature, publicKey: certParsed.identPubk),
    pubKeyDer: certParsed.certPubk,
    validFrom: validFrom,
    validTo: validTo,
  )

proc verify*(self: P2pCertificate): bool =
  ## Verifies that P2pCertificate has signature that was signed by owner of the certificate.
  ##
  ## Parameters:
  ## - `self`: The P2pCertificate.
  ## 
  ## Returns:
  ## `true` if certificate is valid.

  let currentTime = now().utc().toTime()
  if not (currentTime >= self.validFrom and currentTime < self.validTo):
    return false

  var sig: Signature
  var key: PublicKey
  if sig.init(self.extension.signature) and key.init(self.extension.publicKey):
    let msg = makeSignatureMessage(self.pubKeyDer)
    return sig.verify(msg, key)

  return false
