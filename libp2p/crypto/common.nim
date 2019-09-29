## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements interface with BearSSL library sources.
import strutils
from os import DirSep

const
  bearPath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep &
             "BearSSL" & DirSep
  bearSrcPath = bearPath & "src"
  bearIncPath = bearPath & "inc"
  bearIntPath = bearSrcPath & DirSep & "int" & DirSep
  bearCodecPath = bearSrcPath & DirSep & "codec" & DirSep
  bearRandPath = bearSrcPath & DirSep & "rand" & DirSep
  bearRsaPath = bearSrcPath & DirSep & "rsa" & DirSep
  bearEcPath = bearSrcPath & DirSep & "ec" & DirSep
  bearX509Path = bearSrcPath & DirSep & "x509" & DirSep
  bearMacPath = bearSrcPath & DirSep & "mac" & DirSep
  bearHashPath = bearSrcPath & DirSep & "hash" & DirSep

{.passC: "-I" & bearSrcPath}
{.passC: "-I" & bearIncPath}

when defined(windows):
  {.passC: "-DBR_USE_WIN32_TIME=1".}
  {.passC: "-DBR_USE_WIN32_RAND=1".}
else:
  {.passC: "-DBR_USE_UNIX_TIME=1".}
  {.passC: "-DBR_USE_URANDOM=1".}

when system.cpuEndian == bigEndian:
  {.passC: "-DBR_BE_UNALIGNED=1".}
else:
  {.passC: "-DBR_LE_UNALIGNED=1".}

{.pragma: bearssl_func, importc, cdecl.}

when sizeof(int) == 8:
  {.passC: "-DBR_64=1".}
  {.passC:" -DBR_amd64=1".}
  when defined(vcc):
    {.passC: "-DBR_UMUL128=1".}
  else:
    {.passC: "-DBR_INT128=1".}

  ## Codec sources
  {.compile: bearCodecPath & "ccopy.c".}
  {.compile: bearCodecPath & "enc64be.c".}
  {.compile: bearCodecPath & "dec64be.c".}
  {.compile: bearCodecPath & "enc32be.c".}
  {.compile: bearCodecPath & "dec32be.c".}
  {.compile: bearCodecPath & "pemenc.c".}
  {.compile: bearCodecPath & "pemdec.c".}

  ## Big integer sources
  {.compile: bearIntPath & "i31_add.c".}
  {.compile: bearIntPath & "i31_bitlen.c".}
  {.compile: bearIntPath & "i31_decmod.c".}
  {.compile: bearIntPath & "i31_decode.c".}
  {.compile: bearIntPath & "i31_decred.c".}
  {.compile: bearIntPath & "i31_encode.c".}
  {.compile: bearIntPath & "i31_fmont.c".}
  {.compile: bearIntPath & "i31_iszero.c".}
  {.compile: bearIntPath & "i31_moddiv.c".}
  {.compile: bearIntPath & "i31_modpow.c".}
  {.compile: bearIntPath & "i31_modpow2.c".}
  {.compile: bearIntPath & "i31_montmul.c".}
  {.compile: bearIntPath & "i31_mulacc.c".}
  {.compile: bearIntPath & "i31_muladd.c".}
  {.compile: bearIntPath & "i31_ninv31.c".}
  {.compile: bearIntPath & "i31_reduce.c".}
  {.compile: bearIntPath & "i31_rshift.c".}
  {.compile: bearIntPath & "i31_sub.c".}
  {.compile: bearIntPath & "i31_tmont.c".}

  ## Additional integer sources
  {.compile: bearIntPath & "i32_div32.c".}
  {.compile: bearIntPath & "i62_modpow2.c".}

  ## Random generator sources
  {.compile: bearRandPath & "sysrng.c".}
  {.compile: bearRandPath & "hmac_drbg.c".}
  {.compile: bearRandPath & "aesctr_drbg.c".}

  ## HMAC sources
  {.compile: bearMacPath & "hmac.c".}
  {.compile: bearMacPath & "hmac_ct.c".}

  ## HASH sources
  {.compile: bearHashPath & "mgf1.c".}
  {.compile: bearHashPath & "ghash_ctmul64.c".}
  {.compile: bearHashPath & "sha2small.c".} # SHA2-224/256
  {.compile: bearHashPath & "sha2big.c".} # SHA2-384/512

  ## RSA sources
  {.compile: bearRsaPath & "rsa_i31_keygen_inner.c".}
  {.compile: bearRsaPath & "rsa_i62_keygen.c".}
  {.compile: bearRsaPath & "rsa_i62_oaep_decrypt.c".}
  {.compile: bearRsaPath & "rsa_i62_oaep_encrypt.c".}
  {.compile: bearRsaPath & "rsa_i62_pkcs1_sign.c".}
  {.compile: bearRsaPath & "rsa_i62_pkcs1_vrfy.c".}
  {.compile: bearRsaPath & "rsa_i62_priv.c".}
  {.compile: bearRsaPath & "rsa_i62_pub.c".}
  {.compile: bearRsaPath & "rsa_oaep_pad.c".}
  {.compile: bearRsaPath & "rsa_oaep_unpad.c".}
  {.compile: bearRsaPath & "rsa_pkcs1_sig_pad.c".}
  {.compile: bearRsaPath & "rsa_pkcs1_sig_unpad.c".}
  {.compile: bearRsaPath & "rsa_ssl_decrypt.c".}
  {.compile: bearRsaPath & "rsa_default_keygen.c".}
  {.compile: bearRsaPath & "rsa_i31_modulus.c".}
  {.compile: bearRsaPath & "rsa_i31_privexp.c".}
  {.compile: bearRsaPath & "rsa_i31_pubexp.c".}
  {.compile: bearRsaPath & "rsa_default_modulus.c".}
  {.compile: bearRsaPath & "rsa_default_privexp.c".}
  {.compile: bearRsaPath & "rsa_default_pubexp.c".}
  {.compile: bearRsaPath & "rsa_default_pkcs1_sign.c".}
  {.compile: bearRsaPath & "rsa_default_pkcs1_vrfy.c".}

  ## Elliptic Curve sources
  {.compile: bearEcPath & "ec_all_m31.c".}
  {.compile: bearEcPath & "ec_default.c".}
  {.compile: bearEcPath & "ec_keygen.c".}
  {.compile: bearEcPath & "ec_c25519_m31.c".}
  {.compile: bearEcPath & "ec_c25519_m64.c".}
  {.compile: bearEcPath & "ec_p256_m31.c".}
  {.compile: bearEcPath & "ec_p256_m64.c".}
  {.compile: bearEcPath & "ec_curve25519.c".}
  {.compile: bearEcPath & "ec_prime_i31.c".}
  {.compile: bearEcPath & "ec_pubkey.c".}
  {.compile: bearEcPath & "ec_secp256r1.c".}
  {.compile: bearEcPath & "ec_secp384r1.c".}
  {.compile: bearEcPath & "ec_secp521r1.c".}
  {.compile: bearEcPath & "ecdsa_i31_bits.c".}
  {.compile: bearEcPath & "ecdsa_i31_sign_raw.c".}
  {.compile: bearEcPath & "ecdsa_i31_sign_asn1.c".}
  {.compile: bearEcPath & "ecdsa_i31_vrfy_asn1.c".}
  {.compile: bearEcPath & "ecdsa_i31_vrfy_raw.c".}
  {.compile: bearEcPath & "ecdsa_rta.c".}
  {.compile: bearEcPath & "ecdsa_atr.c".}

elif sizeof(int) == 4:

  ## Codec sources
  {.compile: bearCodecPath & "ccopy.c".}
  {.compile: bearCodecPath & "enc64be.c".}
  {.compile: bearCodecPath & "dec64be.c".}
  {.compile: bearCodecPath & "enc32be.c".}
  {.compile: bearCodecPath & "dec32be.c".}
  {.compile: bearCodecPath & "pemenc.c".}
  {.compile: bearCodecPath & "pemdec.c".}

  ## Big integer sources
  {.compile: bearIntPath & "i31_add.c".}
  {.compile: bearIntPath & "i31_bitlen.c".}
  {.compile: bearIntPath & "i31_decmod.c".}
  {.compile: bearIntPath & "i31_decode.c".}
  {.compile: bearIntPath & "i31_decred.c".}
  {.compile: bearIntPath & "i31_encode.c".}
  {.compile: bearIntPath & "i31_fmont.c".}
  {.compile: bearIntPath & "i31_iszero.c".}
  {.compile: bearIntPath & "i31_moddiv.c".}
  {.compile: bearIntPath & "i31_modpow.c".}
  {.compile: bearIntPath & "i31_modpow2.c".}
  {.compile: bearIntPath & "i31_montmul.c".}
  {.compile: bearIntPath & "i31_mulacc.c".}
  {.compile: bearIntPath & "i31_muladd.c".}
  {.compile: bearIntPath & "i31_ninv31.c".}
  {.compile: bearIntPath & "i31_reduce.c".}
  {.compile: bearIntPath & "i31_rshift.c".}
  {.compile: bearIntPath & "i31_sub.c".}
  {.compile: bearIntPath & "i31_tmont.c".}

  ## Additional integer sources
  {.compile: bearIntPath & "i32_div32.c".}

  ## Random generator sources
  {.compile: bearRandPath & "sysrng.c".}
  {.compile: bearRandPath & "hmac_drbg.c".}
  {.compile: bearRandPath & "aesctr_drbg.c".}

  ## HMAC sources
  {.compile: bearMacPath & "hmac.c".}
  {.compile: bearMacPath & "hmac_ct.c".}

  ## HASH sources
  {.compile: bearHashPath & "mgf1.c".}
  {.compile: bearHashPath & "ghash_ctmul.c".}
  {.compile: bearHashPath & "sha2small.c".} # SHA2-224/256
  {.compile: bearHashPath & "sha2big.c".} # SHA2-384/512

  ## RSA sources
  {.compile: bearRsaPath & "rsa_i31_keygen_inner.c".}
  {.compile: bearRsaPath & "rsa_i31_keygen.c".}
  {.compile: bearRsaPath & "rsa_i31_oaep_decrypt.c".}
  {.compile: bearRsaPath & "rsa_i31_oaep_encrypt.c".}
  {.compile: bearRsaPath & "rsa_i31_pkcs1_sign.c".}
  {.compile: bearRsaPath & "rsa_i31_pkcs1_vrfy.c".}
  {.compile: bearRsaPath & "rsa_i31_priv.c".}
  {.compile: bearRsaPath & "rsa_i31_pub.c".}
  {.compile: bearRsaPath & "rsa_oaep_pad.c".}
  {.compile: bearRsaPath & "rsa_oaep_unpad.c".}
  {.compile: bearRsaPath & "rsa_pkcs1_sig_pad.c".}
  {.compile: bearRsaPath & "rsa_pkcs1_sig_unpad.c".}
  {.compile: bearRsaPath & "rsa_ssl_decrypt.c".}
  {.compile: bearRsaPath & "rsa_default_keygen.c".}
  {.compile: bearRsaPath & "rsa_i31_modulus.c".}
  {.compile: bearRsaPath & "rsa_i31_privexp.c".}
  {.compile: bearRsaPath & "rsa_i31_pubexp.c".}
  {.compile: bearRsaPath & "rsa_default_modulus.c".}
  {.compile: bearRsaPath & "rsa_default_privexp.c".}
  {.compile: bearRsaPath & "rsa_default_pubexp.c".}
  {.compile: bearRsaPath & "rsa_default_pkcs1_sign.c".}
  {.compile: bearRsaPath & "rsa_default_pkcs1_vrfy.c".}

  ## Elliptic Curve sources
  {.compile: bearEcPath & "ec_all_m31.c".}
  {.compile: bearEcPath & "ec_default.c".}
  {.compile: bearEcPath & "ec_keygen.c".}
  {.compile: bearEcPath & "ec_c25519_m31.c".}
  {.compile: bearEcPath & "ec_p256_m31.c".}
  {.compile: bearEcPath & "ec_curve25519.c".}
  {.compile: bearEcPath & "ec_prime_i31.c".}
  {.compile: bearEcPath & "ec_pubkey.c".}
  {.compile: bearEcPath & "ec_secp256r1.c".}
  {.compile: bearEcPath & "ec_secp384r1.c".}
  {.compile: bearEcPath & "ec_secp521r1.c".}
  {.compile: bearEcPath & "ecdsa_i31_bits.c".}
  {.compile: bearEcPath & "ecdsa_i31_sign_raw.c".}
  {.compile: bearEcPath & "ecdsa_i31_sign_asn1.c".}
  {.compile: bearEcPath & "ecdsa_i31_vrfy_asn1.c".}
  {.compile: bearEcPath & "ecdsa_i31_vrfy_raw.c".}
  {.compile: bearEcPath & "ecdsa_rta.c".}
  {.compile: bearEcPath & "ecdsa_atr.c".}

else:
  error("Sorry, your target architecture is not supported!")

const
  BR_EC_SECP256R1* = 23
  BR_EC_SECP384R1* = 24
  BR_EC_SECP521R1* = 25

  BR_EC_KBUF_PRIV_MAX_SIZE* = 72
  BR_EC_KBUF_PUB_MAX_SIZE* = 145

type
  BrHashClass* {.importc: "br_hash_class",
                 header: "bearssl_hash.h", bycopy.} = object
    contextSize* {.importc: "context_size".}: int
    desc* {.importc: "desc".}: uint32
    init* {.importc: "init".}: proc (ctx: ptr ptr BrHashClass) {.cdecl.}
    update* {.importc: "update".}: proc (ctx: ptr ptr BrHashClass,
                                         data: pointer, len: int) {.cdecl.}
    output* {.importc: "out".}: proc (ctx: ptr ptr BrHashClass,
                                     dst: pointer) {.cdecl.}
    state* {.importc: "state".}: proc (ctx: ptr ptr BrHashClass,
                                       dst: pointer): uint64 {.cdecl.}
    setState* {.importc: "set_state".}: proc (ctx: ptr ptr BrHashClass,
                                              stb: pointer,
                                              count: uint64) {.cdecl.}

  BrMd5Context* {.importc: "br_md5_context",
                  header: "bearssl_hash.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrHashClass
    buf* {.importc: "buf".}: array[64, cuchar]
    count* {.importc: "count".}: uint64
    val* {.importc: "val".}: array[4, uint32]

  BrMd5sha1Context* {.importc: "br_md5sha1_context",
                      header: "bearssl_hash.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrHashClass
    buf* {.importc: "buf".}: array[64, cuchar]
    count* {.importc: "count".}: uint64
    valMd5* {.importc: "val_md5".}: array[4, uint32]
    valSha1* {.importc: "val_sha1".}: array[5, uint32]

  Sha1Context* {.importc: "br_sha1_context",
                 header: "bearssl_hash.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrHashClass
    buf* {.importc: "buf".}: array[64, cuchar]
    count* {.importc: "count".}: uint64
    val* {.importc: "val".}: array[5, uint32]

  BrSha512Context* = BrSha384Context
  BrSha384Context* {.importc: "br_sha384_context",
                     header: "bearssl_hash.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrHashClass
    buf* {.importc: "buf".}: array[128, cuchar]
    count* {.importc: "count".}: uint64
    val* {.importc: "val".}: array[8, uint64]

  BrSha256Context* = BrSha224Context
  BrSha224Context* {.importc: "br_sha224_context",
                     header: "bearssl_hash.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrHashClass
    buf* {.importc: "buf".}: array[64, cuchar]
    count* {.importc: "count".}: uint64
    val* {.importc: "val".}: array[8, uint32]

  BrHashCompatContext* {.importc: "br_hash_compat_context",
                         header: "bearssl_hash.h", bycopy.} = object {.union.}
    vtable* {.importc: "vtable".}: ptr BrHashClass
    md5* {.importc: "md5".}: BrMd5Context
    sha1* {.importc: "sha1".}: Sha1Context
    sha224* {.importc: "sha224".}: BrSha224Context
    sha256* {.importc: "sha256".}: BrSha256Context
    sha384* {.importc: "sha384".}: BrSha384Context
    sha512* {.importc: "sha512".}: BrSha512Context
    md5sha1* {.importc: "md5sha1".}: BrMd5sha1Context

  BrPrngClass* {.importc: "br_prng_class",
                 header: "bearssl_rand.h", bycopy.} = object
    contextSize* {.importc: "context_size".}: int
    init* {.importc: "init".}: proc (ctx: ptr ptr BrPrngClass, params: pointer,
                                     seed: pointer, seedLen: int) {.cdecl.}
    generate* {.importc: "generate".}: proc (ctx: ptr ptr BrPrngClass,
                                             output: pointer,
                                             length: int) {.cdecl.}
    update* {.importc: "update".}: proc (ctx: ptr ptr BrPrngClass,
                                         seed: pointer, seedLen: int) {.cdecl.}

  BrHmacDrbgContext* {.importc: "br_hmac_drbg_context",
                       header: "bearssl_rand.h", bycopy.} = object
    vtable* {.importc: "vtable".}: ptr BrPrngClass
    k* {.importc: "K".}: array[64, cuchar]
    v* {.importc: "V".}: array[64, cuchar]
    digestClass* {.importc: "digest_class".}: ptr BrHashClass

  BrRsaPublicKey* {.importc: "br_rsa_public_key",
                    header: "bearssl_rsa.h", bycopy.} = object
    n* {.importc: "n".}: ptr cuchar
    nlen* {.importc: "nlen".}: int
    e* {.importc: "e".}: ptr cuchar
    elen* {.importc: "elen".}: int

  BrRsaPrivateKey* {.importc: "br_rsa_private_key",
                     header: "bearssl_rsa.h", bycopy.} = object
    nBitlen* {.importc: "n_bitlen".}: uint32
    p* {.importc: "p".}: ptr cuchar
    plen* {.importc: "plen".}: int
    q* {.importc: "q".}: ptr cuchar
    qlen* {.importc: "qlen".}: int
    dp* {.importc: "dp".}: ptr cuchar
    dplen* {.importc: "dplen".}: int
    dq* {.importc: "dq".}: ptr cuchar
    dqlen* {.importc: "dqlen".}: int
    iq* {.importc: "iq".}: ptr cuchar
    iqlen* {.importc: "iqlen".}: int

  BrEcPublicKey* {.importc: "br_ec_public_key", header: "bearssl_ec.h",
                   bycopy.} = object
    curve* {.importc: "curve".}: cint
    q* {.importc: "q".}: ptr cuchar
    qlen* {.importc: "qlen".}: int

  BrEcPrivateKey* {.importc: "br_ec_private_key", header: "bearssl_ec.h",
                    bycopy.} = object
    curve* {.importc: "curve".}: cint
    x* {.importc: "x".}: ptr cuchar
    xlen* {.importc: "xlen".}: int

  BrEcImplementation* {.importc: "br_ec_impl", header: "bearssl_ec.h",
                        bycopy.} = object
    supportedCurves* {.importc: "supported_curves".}: uint32
    generator* {.importc: "generator".}: proc (curve: cint,
                                          length: ptr int): ptr cuchar {.cdecl, gcsafe.}
    order* {.importc: "order".}: proc (curve: cint,
                                       length: ptr int): ptr cuchar {.cdecl, gcsafe.}
    xoff* {.importc: "xoff".}: proc (curve: cint,
                                     length: ptr int): int {.cdecl, gcsafe.}
    mul* {.importc: "mul".}: proc (g: ptr cuchar, glen: int,
                                   x: ptr cuchar, xlen: int,
                                   curve: cint): uint32 {.cdecl, gcsafe.}
    mulgen* {.importc: "mulgen".}: proc (r: ptr cuchar,
                                         x: ptr cuchar, xlen: int,
                                         curve: cint): int {.cdecl, gcsafe.}
    muladd* {.importc: "muladd".}: proc (a: ptr cuchar, b: ptr cuchar,
                                         length: int, x: ptr cuchar, xlen: int,
                                         y: ptr cuchar, ylen: int,
                                         curve: cint): uint32 {.cdecl, gcsafe.}

  BrPrngSeeder* = proc (ctx: ptr ptr BrPrngClass): cint {.cdecl.}
  BrRsaKeygen* = proc (ctx: ptr ptr BrPrngClass,
                       sk: ptr BrRsaPrivateKey, bufsec: ptr byte,
                       pk: ptr BrRsaPublicKey, bufpub: ptr byte,
                       size: cuint, pubexp: uint32): uint32 {.cdecl.}
  BrRsaComputeModulus* = proc (n: pointer,
                               sk: ptr BrRsaPrivateKey): int {.cdecl.}
  BrRsaComputePubexp* = proc (sk: ptr BrRsaPrivateKey): uint32 {.cdecl.}
  BrRsaComputePrivexp* = proc (d: pointer,
                               sk: ptr BrRsaPrivateKey,
                               pubexp: uint32): int {.cdecl.}
  BrRsaPkcs1Verify* = proc (x: ptr cuchar, xlen: int,
                            hash_oid: ptr cuchar, hash_len: int,
                            pk: ptr BrRsaPublicKey,
                            hash_out: ptr cuchar): uint32 {.cdecl.}
  BrPemDecoderProc* = proc (destctx: pointer, src: pointer,
                            length: int) {.cdecl.}
  BrRsaPkcs1Sign* = proc (hash_oid: ptr cuchar, hash: ptr cuchar, hash_len: int,
                          pk: ptr BrRsaPrivateKey,
                          x: ptr cuchar): uint32 {.cdecl.}

proc brPrngSeederSystem*(name: cstringArray): BrPrngSeeder {.cdecl,
     importc: "br_prng_seeder_system", header: "bearssl_rand.h".}

proc brHmacDrbgInit*(ctx: ptr BrHmacDrbgContext, digestClass: ptr BrHashClass,
                     seed: pointer, seedLen: int) {.
     cdecl, importc: "br_hmac_drbg_init", header: "bearssl_rand.h".}

proc brRsaKeygenGetDefault*(): BrRsaKeygen {.
     cdecl, importc: "br_rsa_keygen_get_default", header: "bearssl_rsa.h".}

proc BrRsaPkcs1SignGetDefault*(): BrRsaPkcs1Sign {.
     cdecl, importc: "br_rsa_pkcs1_sign_get_default", header: "bearssl_rsa.h".}

proc BrRsaPkcs1VrfyGetDefault*(): BrRsaPkcs1Verify {.
     cdecl, importc: "br_rsa_pkcs1_vrfy_get_default", header: "bearssl_rsa.h".}

proc brRsaComputeModulusGetDefault*(): BrRsaComputeModulus {.
     cdecl, importc: "br_rsa_compute_modulus_get_default",
     header: "bearssl_rsa.h".}

proc brRsaComputePubexpGetDefault*(): BrRsaComputePubexp {.
     cdecl, importc: "br_rsa_compute_pubexp_get_default",
     header: "bearssl_rsa.h".}

proc brRsaComputePrivexpGetDefault*(): BrRsaComputePrivexp {.
     cdecl, importc: "br_rsa_compute_privexp_get_default",
     header: "bearssl_rsa.h".}

proc brEcGetDefault*(): ptr BrEcImplementation {.
     cdecl, importc: "br_ec_get_default", header: "bearssl_ec.h".}

proc brEcKeygen*(ctx: ptr ptr BrPrngClass, impl: ptr BrEcImplementation,
                 sk: ptr BrEcPrivateKey, keybuf: ptr byte,
                 curve: cint): int {.cdecl,
     importc: "br_ec_keygen", header: "bearssl_ec.h".}

proc brEcComputePublicKey*(impl: ptr BrEcImplementation, pk: ptr BrEcPublicKey,
                           kbuf: ptr byte, sk: ptr BrEcPrivateKey): int {.
     cdecl, importc: "br_ec_compute_pub", header: "bearssl_ec.h".}

proc brEcdsaSignRaw*(impl: ptr BrEcImplementation, hf: ptr BrHashClass,
                     value: pointer, sk: ptr BrEcPrivateKey,
                     sig: pointer): int {.
     cdecl, importc: "br_ecdsa_i31_sign_raw", header: "bearssl_ec.h".}

proc brEcdsaVerifyRaw*(impl: ptr BrEcImplementation, hash: pointer,
                       hashlen: int, pk: ptr BrEcPublicKey, sig: pointer,
                       siglen: int): uint32 {.
     cdecl, importc: "br_ecdsa_i31_vrfy_raw", header: "bearssl_ec.h".}

proc brEcdsaSignAsn1*(impl: ptr BrEcImplementation, hf: ptr BrHashClass,
                     value: pointer, sk: ptr BrEcPrivateKey,
                     sig: pointer): int {.
     cdecl, importc: "br_ecdsa_i31_sign_asn1", header: "bearssl_ec.h".}

proc brEcdsaVerifyAsn1*(impl: ptr BrEcImplementation, hash: pointer,
                        hashlen: int, pk: ptr BrEcPublicKey, sig: pointer,
                        siglen: int): uint32 {.
     cdecl, importc: "br_ecdsa_i31_vrfy_asn1", header: "bearssl_ec.h".}

var sha256Vtable* {.importc: "br_sha256_vtable",
                    header: "bearssl_hash.h".}: BrHashClass
var sha384Vtable* {.importc: "br_sha384_vtable",
                    header: "bearssl_hash.h".}: BrHashClass
var sha512Vtable* {.importc: "br_sha512_vtable",
                    header: "bearssl_hash.h".}: BrHashClass

template brRsaPrivateKeyBufferSize*(size: int): int =
  # BR_RSA_KBUF_PRIV_SIZE(size)
  (5 * ((size + 15) shr 4))

template brRsaPublicKeyBufferSize*(size: int): int =
  # BR_RSA_KBUF_PUB_SIZE(size)
  (4 + ((size + 7) shr 3))
