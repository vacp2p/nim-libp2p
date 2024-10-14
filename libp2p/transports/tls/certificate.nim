# Nim-LibP2P
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils, strutils]

import stew/byteutils
import chronicles

import mbedtls/pk
import mbedtls/ctr_drbg
import mbedtls/entropy
import mbedtls/ecp
import mbedtls/sha256
import mbedtls/md
import mbedtls/asn1
import mbedtls/asn1write
import mbedtls/x509
import mbedtls/x509_crt
import mbedtls/oid
import mbedtls/debug
import mbedtls/error
import nimcrypto/utils
import ../../crypto/crypto

logScope:
  topics = "libp2p tls certificate"

# Constants and OIDs
const
  P2P_SIGNING_PREFIX = "libp2p-tls-handshake:"
  SIGNATURE_ALG = MBEDTLS_MD_SHA256
  EC_GROUP_ID = MBEDTLS_ECP_DP_SECP256R1
  LIBP2P_EXT_OID_DER: array[10, byte] =
    [0x2B, 0x06, 0x01, 0x04, 0x01, 0x83, 0xA2, 0x5A, 0x01, 0x01]
    # "1.3.6.1.4.1.53594.1.1"

# Exception types for TLS certificate errors
type
  TLSCertificateError* = object of Exception
  ASN1EncodingError* = object of TLSCertificateError
  KeyGenerationError* = object of TLSCertificateError
  CertificateCreationError* = object of TLSCertificateError
  CertificateParsingError* = object of TLSCertificateError
  IdentityPubKeySerializationError* = object of TLSCertificateError
  IdentitySigningError* = object of TLSCertificateError

# Define the P2pExtension and P2pCertificate types
type
  P2pExtension* = object
    publicKey*: seq[byte]
    signature*: seq[byte]

  P2pCertificate* = object
    certificate*: mbedtls_x509_crt
    extension*: P2pExtension

proc ptrInc*(p: ptr byte, n: uint): ptr byte =
  ## Utility function to increment a pointer by n bytes.
  cast[ptr byte](cast[uint](p) + n)

proc generateSignedKey(
    signature: seq[byte], pubKey: seq[byte]
): seq[byte] {.raises: [ASN1EncodingError].} =
  ## Generates the ASN.1-encoded SignedKey structure.
  ##
  ## The SignedKey structure contains the public key and its signature,
  ## encoded as a SEQUENCE of two OCTET STRINGs.
  ##
  ## Parameters:
  ## - `signature`: The signature bytes.
  ## - `pubKey`: The public key bytes.
  ##
  ## Returns:
  ## A sequence of bytes representing the ASN.1-encoded SignedKey.
  ##
  ## Raises:
  ## - `ASN1EncodingError` if ASN.1 encoding fails.
  const extValueSize = 256 # Buffer size for ASN.1 encoding
  var
    extValue: array[extValueSize, byte]
    extPtr: ptr byte = addr extValue[extValueSize - 1]
      # Start at the end of the buffer as mbedtls_asn1_write_octet_string works backwards in data buffer.
    startPtr: ptr byte = addr extValue[0]
    len = 0

  # Write signature OCTET STRING
  let retSig = mbedtls_asn1_write_octet_string(
    addr extPtr, startPtr, unsafeAddr signature[0], signature.len.uint
  )
  if retSig < 0:
    raise newException(ASN1EncodingError, "Failed to write signature OCTET STRING")
  len += retSig

  # Write publicKey OCTET STRING
  let retPub = mbedtls_asn1_write_octet_string(
    addr extPtr, startPtr, unsafeAddr pubKey[0], pubKey.len.uint
  )
  if retPub < 0:
    raise newException(ASN1EncodingError, "Failed to write publicKey OCTET STRING")
  len += retPub

  # Total length of the SEQUENCE contents
  let contentLen = retSig + retPub
  # Write SEQUENCE length
  let retLen = mbedtls_asn1_write_len(addr extPtr, startPtr, contentLen.uint)
  if retLen < 0:
    raise newException(ASN1EncodingError, "Failed to write SEQUENCE length")
  len += retLen

  # Write SEQUENCE tag
  let retTag = mbedtls_asn1_write_tag(
    addr extPtr, startPtr, MBEDTLS_ASN1_CONSTRUCTED or MBEDTLS_ASN1_SEQUENCE
  )
  if retTag < 0:
    raise newException(ASN1EncodingError, "Failed to write SEQUENCE tag")
  len += retTag

  # Calculate dataOffset based on the accumulated length
  let dataOffset = extValueSize - len - 1

  # Extract the relevant portion of extValue as a seq[byte]
  let extValueSeq = toSeq(extValue[dataOffset ..< extValueSize])

  # Return the extension content
  return extValueSeq

proc makeLibp2pExtension(
    identityKeypair: KeyPair, certificateKeypair: mbedtls_pk_context
): seq[byte] {.
    raises: [
      CertificateCreationError, IdentityPubKeySerializationError, IdentitySigningError,
      ASN1EncodingError, TLSCertificateError,
    ]
.} =
  ## Creates the libp2p extension containing the SignedKey.
  ##
  ## The libp2p extension is an ASN.1-encoded structure that includes
  ## the public key and its signature over the certificate's public key.
  ##
  ## Parameters:
  ## - `identityKeypair`: The peer's identity key pair.
  ## - `certificateKeypair`: The key pair used for the certificate.
  ##
  ## Returns:
  ## A sequence of bytes representing the libp2p extension.
  ##
  ## Raises:
  ## - `CertificateCreationError` if public key serialization fails.
  ## - `IdentityPubKeySerializationError` if serialization of identity public key fails.
  ## - `IdentitySigningError` if signing the hash fails.
  ## - `ASN1EncodingError` if ASN.1 encoding fails.

  # Serialize the Certificate's Public Key
  var
    certPubKeyDer: array[512, byte]
    certPubKeyDerLen: cint

  certPubKeyDerLen = mbedtls_pk_write_pubkey_der(
    unsafeAddr certificateKeypair, addr certPubKeyDer[0], certPubKeyDer.len.uint
  )
  if certPubKeyDerLen < 0:
    raise newException(
      CertificateCreationError, "Failed to write certificate public key in DER format"
    )

  # Adjust pointer to the start of the data
  let certPubKeyDerPtr = addr certPubKeyDer[certPubKeyDer.len - certPubKeyDerLen]

  # Create the Message to Sign
  var msg = newSeq[byte](P2P_SIGNING_PREFIX.len + certPubKeyDerLen.int.int)

  # Copy the prefix into msg
  for i in 0 ..< P2P_SIGNING_PREFIX.len:
    msg[i] = byte(P2P_SIGNING_PREFIX[i])

  # Copy the public key DER into msg
  copyMem(addr msg[P2P_SIGNING_PREFIX.len], certPubKeyDerPtr, certPubKeyDerLen.int)

  # Compute SHA-256 hash of the message
  var hash: array[32, byte]
  let hashRet = mbedtls_sha256(
    msg[0].addr, msg.len.uint, addr hash[0], 0 # 0 for SHA-256
  )
  if hashRet != 0:
    # Since hashing failure is critical and unlikely, we can raise a general exception
    raise newException(TLSCertificateError, "Failed to compute SHA-256 hash")

  # Sign the hash with the Identity Key
  let signatureResult = identityKeypair.seckey.sign(hash)
  if signatureResult.isErr:
    raise newException(
      IdentitySigningError, "Failed to sign the hash with the identity key"
    )
  let signature = signatureResult.get().data

  # Get the public key bytes
  let pubKeyBytesResult = identityKeypair.pubkey.getBytes()
  if pubKeyBytesResult.isErr:
    raise newException(
      IdentityPubKeySerializationError, "Failed to get identity public key bytes"
    )
  let pubKeyBytes = pubKeyBytesResult.get()

  # Generate the SignedKey ASN.1 structure
  return generateSignedKey(signature, pubKeyBytes)

proc generate*(
    identityKeyPair: KeyPair
): (seq[byte], seq[byte]) {.
    raises: [
      KeyGenerationError, CertificateCreationError, ASN1EncodingError,
      IdentityPubKeySerializationError, IdentitySigningError, TLSCertificateError,
    ]
.} =
  ## Generates a self-signed X.509 certificate with the libp2p extension.
  ##
  ## Parameters:
  ## - `identityKeyPair`: The peer's identity key pair.
  ##
  ## Returns:
  ## A tuple containing:
  ## - The DER-encoded certificate.
  ## - The DER-encoded private key.
  ##
  ## Raises:
  ## - `KeyGenerationError` if key generation fails.
  ## - `CertificateCreationError` if certificate creation fails.
  ## - `ASN1EncodingError` if encoding fails.
  # Initialize entropy and DRBG contexts
  var
    entropy = mbedtls_entropy_context()
    ctrDrbg = mbedtls_ctr_drbg_context()
    crt: mbedtls_x509write_cert
    certKey: mbedtls_pk_context
    ret: cint

  mbedtls_entropy_init(addr entropy)
  mbedtls_ctr_drbg_init(addr ctrDrbg)
  mbedtls_x509write_crt_init(addr crt)
  mbedtls_pk_init(addr certKey)

  defer:
    mbedtls_entropy_free(addr entropy)
    mbedtls_ctr_drbg_free(addr ctrDrbg)
    mbedtls_pk_free(addr certKey)
    mbedtls_x509write_crt_free(addr crt)

  # Seed the random number generator
  let personalization = "libp2p_tls"
  ret = mbedtls_ctr_drbg_seed(
    addr ctrDrbg,
    mbedtls_entropy_func,
    addr entropy,
    cast[ptr byte](personalization.cstring),
    personalization.len.uint,
  )
  if ret != 0:
    raise newException(KeyGenerationError, "Failed to seed CTR_DRBG")

  # Initialize certificate key
  ret = mbedtls_pk_setup(addr certKey, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY))
  if ret != 0:
    raise newException(KeyGenerationError, "Failed to set up certificate key context")

  # Generate key pair for the certificate
  let G =
    try:
      mb_pk_ec(certKey)
    except MbedTLSError as e:
      raise newException(KeyGenerationError, e.msg)
  ret = mbedtls_ecp_gen_key(EC_GROUP_ID, G, mbedtls_ctr_drbg_random, addr ctrDrbg)
  if ret != 0:
    raise
      newException(KeyGenerationError, "Failed to generate EC key pair for certificate")

  ## Initialize libp2p extension
  let libp2pExtension = makeLibp2pExtension(identityKeyPair, certKey)

  # Set the Subject and Issuer Name (self-signed)
  ret = mbedtls_x509write_crt_set_subject_name(addr crt, "CN=libp2p.io")
  if ret != 0:
    raise newException(CertificateCreationError, "Failed to set subject name")

  ret = mbedtls_x509write_crt_set_issuer_name(addr crt, "CN=libp2p.io")
  if ret != 0:
    raise newException(CertificateCreationError, "Failed to set issuer name")

  # Set Validity Period
  let notBefore = "19750101000000"
  let notAfter = "40960101000000"
  ret =
    mbedtls_x509write_crt_set_validity(addr crt, notBefore.cstring, notAfter.cstring)
  if ret != 0:
    raise newException(
      CertificateCreationError, "Failed to set certificate validity period"
    )

  # Assign the Public Key to the Certificate
  mbedtls_x509write_crt_set_subject_key(addr crt, addr certKey)
  mbedtls_x509write_crt_set_issuer_key(addr crt, addr certKey) # Self-signed

  # Add the libp2p Extension
  let oid = string.fromBytes(LIBP2P_EXT_OID_DER)
  ret = mbedtls_x509write_crt_set_extension(
    addr crt,
    oid, # OID
    oid.len.uint, # OID length
    0, # Critical flag
    unsafeAddr libp2pExtension[0], # Extension data
    libp2pExtension.len.uint, # Extension data length
  )
  if ret != 0:
    raise newException(
      CertificateCreationError, "Failed to set libp2p extension in certificate"
    )

  # Set Basic Constraints (optional, e.g., CA:FALSE)
  ret = mbedtls_x509write_crt_set_basic_constraints(
    addr crt,
    0, # is_ca
    -1, # max_pathlen (-1 for no limit)
  )
  if ret != 0:
    raise newException(CertificateCreationError, "Failed to set basic constraints")

  # Set Key Usage
  ret = mbedtls_x509write_crt_set_key_usage(
    addr crt, MBEDTLS_X509_KU_DIGITAL_SIGNATURE or MBEDTLS_X509_KU_KEY_ENCIPHERMENT
  )
  if ret != 0:
    raise newException(CertificateCreationError, "Failed to set key usage")

  # Set the MD algorithm
  mbedtls_x509write_crt_set_md_alg(addr crt, SIGNATURE_ALG)

  # Prepare Buffer for Certificate Serialization
  const CERT_BUFFER_SIZE = 4096
  var
    certBuffer: array[CERT_BUFFER_SIZE, byte]
    certLen: cint

  # Write the Certificate in DER Format
  certLen = mbedtls_x509write_crt_der(
    addr crt,
    addr certBuffer[0],
    CERT_BUFFER_SIZE.uint,
    mbedtls_ctr_drbg_random,
    addr ctrDrbg,
  )
  if certLen < 0:
    raise newException(
      CertificateCreationError, "Failed to write certificate in DER format"
    )

  # Adjust the buffer to contain only the DER data
  let certificateDer =
    toSeq(certBuffer[(CERT_BUFFER_SIZE - certLen) ..< CERT_BUFFER_SIZE])

  # Serialize the Private Key in DER Format (PKCS#8)
  var
    privKeyBuffer: array[2048, byte]
    privKeyLen: cint

  privKeyLen = mbedtls_pk_write_key_der(
    addr certKey, addr privKeyBuffer[0], privKeyBuffer.len.uint
  )
  if privKeyLen < 0:
    raise newException(
      CertificateCreationError, "Failed to write private key in DER format"
    )

  # Adjust the buffer to contain only the DER data
  let privateKeyDer =
    toSeq(privKeyBuffer[(privKeyBuffer.len - privKeyLen) ..< privKeyBuffer.len])

  # Return the Serialized Certificate and Private Key
  return (certificateDer, privateKeyDer)

proc libp2pext(
    p_ctx: pointer,
    crt: ptr mbedtls_x509_crt,
    oid: ptr mbedtls_x509_buf,
    critical: cint,
    p: ptr byte,
    endPtr: ptr byte,
): cint {.cdecl.} =
  ## Callback function to parse the libp2p extension.
  ##
  ## This function is used as a callback by mbedtls during certificate parsing
  ## to extract the libp2p extension containing the SignedKey.
  ##
  ## Parameters:
  ## - `p_ctx`: Pointer to the P2pExtension object to store the parsed data.
  ## - `crt`: Pointer to the certificate being parsed.
  ## - `oid`: Pointer to the OID of the extension.
  ## - `critical`: Critical flag of the extension.
  ## - `p`: Pointer to the start of the extension data.
  ## - `endPtr`: Pointer to the end of the extension data.
  ##
  ## Returns:
  ## - 0 on success, or a negative error code on failure.

  # Check if the OID matches the libp2p extension
  if oid.len != LIBP2P_EXT_OID_DER.len:
    return MBEDTLS_ERR_OID_NOT_FOUND # Extension not handled by this callback
  for i in 0 ..< LIBP2P_EXT_OID_DER.len:
    if ptrInc(oid.p, i.uint)[] != LIBP2P_EXT_OID_DER[i]:
      return MBEDTLS_ERR_OID_NOT_FOUND # Extension not handled by this callback

  var parsePtr = p

  # Parse SEQUENCE tag and length
  var len: uint
  if mbedtls_asn1_get_tag(
    addr parsePtr, endPtr, addr len, MBEDTLS_ASN1_CONSTRUCTED or MBEDTLS_ASN1_SEQUENCE
  ) != 0:
    debug "Failed to parse SEQUENCE in libp2p extension"
    return MBEDTLS_ERR_ASN1_UNEXPECTED_TAG

  # Parse publicKey OCTET STRING
  var pubKeyLen: uint
  if mbedtls_asn1_get_tag(
    addr parsePtr, endPtr, addr pubKeyLen, MBEDTLS_ASN1_OCTET_STRING
  ) != 0:
    debug "Failed to parse publicKey OCTET STRING in libp2p extension"
    return MBEDTLS_ERR_ASN1_UNEXPECTED_TAG

  # Extract publicKey
  var publicKey = newSeq[byte](int(pubKeyLen))
  copyMem(addr publicKey[0], parsePtr, int(pubKeyLen))
  parsePtr = ptrInc(parsePtr, pubKeyLen)

  # Parse signature OCTET STRING
  var signatureLen: uint
  if mbedtls_asn1_get_tag(
    addr parsePtr, endPtr, addr signatureLen, MBEDTLS_ASN1_OCTET_STRING
  ) != 0:
    debug "Failed to parse signature OCTET STRING in libp2p extension"
    return MBEDTLS_ERR_ASN1_UNEXPECTED_TAG

  # Extract signature
  var signature = newSeq[byte](int(signatureLen))
  copyMem(addr signature[0], parsePtr, int(signatureLen))

  # Store the publicKey and signature in the P2pExtension
  let extension = cast[ptr P2pExtension](p_ctx)
  extension[].publicKey = publicKey
  extension[].signature = signature

  return 0 # Success

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
  var crt: mbedtls_x509_crt
  mbedtls_x509_crt_init(addr crt)
  defer:
    mbedtls_x509_crt_free(addr crt)

  var extension = P2pExtension()
  let ret = mbedtls_x509_crt_parse_der_with_ext_cb(
    addr crt,
    unsafeAddr certificateDer[0],
    certificateDer.len.uint,
    0,
    libp2pext,
    addr extension,
  )
  if ret != 0:
    raise newException(
      CertificateParsingError, "Failed to parse certificate, error code: " & $ret
    )

  return P2pCertificate(certificate: crt, extension: extension)
