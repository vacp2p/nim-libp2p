import strutils
import hexdump
from os import DirSep

when defined(vcc):
  {.passC: "/Zi /FS".}

const
  bearPath = currentSourcePath.rsplit(DirSep, 1)[0] & DirSep &
             ".." & DirSep & "BearSSL" & DirSep
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

  ## Elliptic Curve sources
  {.compile: bearEcPath & "ec_all_m31.c".}
  {.compile: bearEcPath & "ec_default.c".}
  {.compile: bearEcPath & "ec_keygen.c".}
  {.compile: bearEcPath & "ec_p256_m31.c".}
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

## X509 sources
{.compile: bearX509Path & "asn1enc.c".}
{.compile: bearX509Path & "encode_rsa_pk8der.c".}
{.compile: bearX509Path & "encode_rsa_rawder.c".}
{.compile: bearX509Path & "skey_decoder.c".}

const
  X509_BUFSIZE_KEY* = 520
  X509_BUFSIZE_SIG* = 512

  ERR_X509_OK* = 32
  ERR_X509_INVALID_VALUE* = 33
  ERR_X509_TRUNCATED* = 34
  ERR_X509_EMPTY_CHAIN* = 35
  ERR_X509_INNER_TRUNC* = 36
  ERR_X509_BAD_TAG_CLASS* = 37
  ERR_X509_BAD_TAG_VALUE* = 38
  ERR_X509_INDEFINITE_LENGTH* = 39
  ERR_X509_EXTRA_ELEMENT* = 40
  ERR_X509_UNEXPECTED* = 41
  ERR_X509_NOT_CONSTRUCTED* = 42
  ERR_X509_NOT_PRIMITIVE* = 43
  ERR_X509_PARTIAL_BYTE* = 44
  ERR_X509_BAD_BOOLEAN* = 45
  ERR_X509_OVERFLOW* = 46
  ERR_X509_BAD_DN* = 47
  ERR_X509_BAD_TIME* = 48
  ERR_X509_UNSUPPORTED* = 49
  ERR_X509_LIMIT_EXCEEDED* = 50
  ERR_X509_WRONG_KEY_TYPE* = 51
  ERR_X509_BAD_SIGNATURE* = 52
  ERR_X509_TIME_UNKNOWN* = 53
  ERR_X509_EXPIRED* = 54
  ERR_X509_DN_MISMATCH* = 55
  ERR_X509_BAD_SERVER_NAME* = 56
  ERR_X509_CRITICAL_EXTENSION* = 57
  ERR_X509_NOT_CA* = 58
  ERR_X509_FORBIDDEN_KEY_USAGE* = 59
  ERR_X509_WEAK_PUBLIC_KEY* = 60
  ERR_X509_NOT_TRUSTED* = 62

  BR_PEM_LINE64* = 1
  BR_PEM_CRLF* = 2

  BR_X509_TA_CA* = 0x00000001
  BR_KEYTYPE_RSA* = 1
  BR_KEYTYPE_EC* = 2
  BR_KEYTYPE_KEYX* = 0x00000010
  BR_KEYTYPE_SIGN* = 0x00000020

  BR_PEM_BEGIN_OBJ* = 1
  BR_PEM_END_OBJ* = 2
  BR_PEM_ERROR* = 3

  BR_EC_SECP256R1* = 23
  BR_EC_SECP384R1* = 24
  BR_EC_SECP521R1* = 25

  BR_EC_KBUF_PRIV_MAX_SIZE* = 72
  BR_EC_KBUF_PUB_MAX_SIZE* = 145

type
  MarshalKind* = enum
    RAW, PKCS8

  X509Status* {.pure.} = enum
    OK = ERR_X509_OK,
    INVALID_VALUE = ERR_X509_INVALID_VALUE,
    TRUNCATED = ERR_X509_TRUNCATED,
    EMPTY_CHAIN = ERR_X509_EMPTY_CHAIN,
    INNER_TRUNC = ERR_X509_INNER_TRUNC,
    BAD_TAG_CLASS = ERR_X509_BAD_TAG_CLASS,
    BAD_TAG_VALUE = ERR_X509_BAD_TAG_VALUE,
    INDEFINITE_LENGTH = ERR_X509_INDEFINITE_LENGTH,
    EXTRA_ELEMENT = ERR_X509_EXTRA_ELEMENT,
    UNEXPECTED = ERR_X509_UNEXPECTED,
    NOT_CONSTRUCTED = ERR_X509_NOT_CONSTRUCTED,
    NOT_PRIMITIVE = ERR_X509_NOT_PRIMITIVE,
    PARTIAL_BYTE = ERR_X509_PARTIAL_BYTE,
    BAD_BOOLEAN = ERR_X509_BAD_BOOLEAN,
    OVERFLOW = ERR_X509_OVERFLOW,
    BAD_DN = ERR_X509_BAD_DN,
    BAD_TIME = ERR_X509_BAD_TIME,
    UNSUPPORTED = ERR_X509_UNSUPPORTED,
    LIMIT_EXCEEDED = ERR_X509_LIMIT_EXCEEDED,
    WRONG_KEY_TYPE = ERR_X509_WRONG_KEY_TYPE,
    BAD_SIGNATURE = ERR_X509_BAD_SIGNATURE,
    TIME_UNKNOWN = ERR_X509_TIME_UNKNOWN,
    EXPIRED = ERR_X509_EXPIRED,
    DN_MISMATCH = ERR_X509_DN_MISMATCH,
    BAD_SERVER_NAME = ERR_X509_BAD_SERVER_NAME,
    CRITICAL_EXTENSION = ERR_X509_CRITICAL_EXTENSION,
    NOT_CA = ERR_X509_NOT_CA,
    FORBIDDEN_KEY_USAGE = ERR_X509_FORBIDDEN_KEY_USAGE,
    WEAK_PUBLIC_KEY = ERR_X509_WEAK_PUBLIC_KEY,
    NOT_TRUSTED = ERR_X509_NOT_TRUSTED,
    INCORRECT_VALUE = 100
    MISSING_KEY = 101

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

  BrPublicKeyUnion* {.importc: "no_name", header: "bearssl_x509.h",
                      bycopy.} = object {.union.}
    rsa* {.importc: "rsa".}: BrRsaPublicKey
    ec* {.importc: "ec".}: BrEcPublicKey

  BrPrivateKeyUnion* {.importc: "no_name", header: "bearssl_x509.h",
                       bycopy.} = object {.union.}
    rsa* {.importc: "rsa".}: BrRsaPrivateKey
    ec* {.importc: "ec".}: BrEcPrivateKey

  X509Pkey* {.importc: "br_x509_pkey", header: "bearssl_x509.h",
              bycopy.} = object
    keyType* {.importc: "key_type".}: cuchar
    key* {.importc: "key".}: BrPublicKeyUnion

  BrX509CpuStruct* {.importc: "no_name", header: "bearssl_x509.h",
                     bycopy.} = object
    dp* {.importc: "dp".}: ptr uint32
    rp* {.importc: "rp".}: ptr uint32
    ip* {.importc: "ip".}: ptr cuchar

  BrX509DecoderContext* {.importc: "br_x509_decoder_context",
                          header: "bearssl_x509.h", bycopy.} = object
    pkey* {.importc: "pkey".}: X509Pkey
    cpu* {.importc: "cpu".}: BrX509CpuStruct
    dpStack* {.importc: "dp_stack".}: array[32, uint32]
    rpStack* {.importc: "rp_stack".}: array[32, uint32]
    err* {.importc: "err".}: cint
    pad* {.importc: "pad".}: array[256, cuchar]
    decoded* {.importc: "decoded".}: bool
    notbeforeDays* {.importc: "notbefore_days".}: uint32
    notbeforeSeconds* {.importc: "notbefore_seconds".}: uint32
    notafterDays* {.importc: "notafter_days".}: uint32
    notafterSeconds* {.importc: "notafter_seconds".}: uint32
    isCA* {.importc: "isCA".}: bool
    copyDn* {.importc: "copy_dn".}: cuchar
    appendDnCtx* {.importc: "append_dn_ctx".}: pointer
    appendDn* {.importc: "append_dn".}: proc (ctx: pointer, buf: pointer,
                                              length: int) {.cdecl.}
    hbuf* {.importc: "hbuf".}: ptr cuchar
    hlen* {.importc: "hlen".}: int
    pkeyData* {.importc: "pkey_data".}: array[X509_BUFSIZE_KEY, cuchar]
    signerKeyType* {.importc: "signer_key_type".}: cuchar
    signerHashId* {.importc: "signer_hash_id".}: cuchar

  BrSkeyDecoderContext* {.importc: "br_skey_decoder_context",
                          header: "bearssl_x509.h", bycopy.} = object
    pkey* {.importc: "key".}: BrPrivateKeyUnion
    cpu* {.importc: "cpu".}: BrX509CpuStruct
    dpStack* {.importc: "dp_stack".}: array[32, uint32]
    rpStack* {.importc: "rp_stack".}: array[32, uint32]
    err* {.importc: "err".}: cint
    hbuf* {.importc: "hbuf".}: ptr cuchar
    hlen* {.importc: "hlen".}: int
    pad* {.importc: "pad".}: array[256, cuchar]
    keyType* {.importc: "key_type".}: cuchar
    keyData* {.importc: "key_data".}: array[3 * X509_BUFSIZE_SIG, cuchar]

  BrPemCpuStruct* {.importc: "no_name", header: "bearssl_pem.h",
                    bycopy.} = object
    dp* {.importc: "dp".}: ptr uint32
    rp* {.importc: "rp".}: ptr uint32
    ip* {.importc: "ip".}: ptr cuchar

  BrPemDecoderContext* {.importc: "br_pem_decoder_context",
                         header: "bearssl_pem.h", bycopy.} = object
    cpu* {.importc: "cpu".}: BrPemCpuStruct
    dpStack* {.importc: "dp_stack".}: array[32, uint32]
    rpStack* {.importc: "rp_stack".}: array[32, uint32]
    err* {.importc: "err".}: cint
    hbuf* {.importc: "hbuf".}: ptr cuchar
    hlen* {.importc: "hlen".}: int
    dest* {.importc: "dest".}: proc (destCtx: pointer; src: pointer,
                                     length: int) {.cdecl.}
    destCtx* {.importc: "dest_ctx".}: pointer
    event* {.importc: "event".}: cuchar
    name* {.importc: "name".}: array[128, char]
    buf* {.importc: "buf".}: array[255, cuchar]
    pptr* {.importc: "ptr".}: int

  BrAsn1Uint* {.importc: "br_asn1_uint", header: "inner.h", bycopy.} = object
    data* {.importc: "data".}: ptr cuchar
    length* {.importc: "len".}: int
    asn1len* {.importc: "asn1len".}: int

  BrEcImplementation* {.importc: "br_ec_impl", header: "bearssl_ec.h",
                        bycopy.} = object
    supportedCurves* {.importc: "supported_curves".}: uint32
    generator* {.importc: "generator".}: proc (curve: cint,
                                          length: ptr int): ptr cuchar {.cdecl.}
    order* {.importc: "order".}: proc (curve: cint,
                                       length: ptr int): ptr cuchar {.cdecl.}
    xoff* {.importc: "xoff".}: proc (curve: cint,
                                     length: ptr int): int {.cdecl.}
    mul* {.importc: "mul".}: proc (g: ptr cuchar, glen: int,
                                   x: ptr cuchar, xlen: int,
                                   curve: cint): uint32 {.cdecl.}
    mulgen* {.importc: "mulgen".}: proc (r: ptr cuchar,
                                         x: ptr cuchar, xlen: int,
                                         curve: cint): int {.cdecl.}
    muladd* {.importc: "muladd".}: proc (a: ptr cuchar, b: ptr cuchar,
                                         length: int, x: ptr cuchar, xlen: int,
                                         y: ptr cuchar, ylen: int,
                                         curve: cint): uint32 {.cdecl.}

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

type
  PemObject* = object
    name*: string
    data*: seq[byte]

  PemList* = seq[PemObject]

proc brRsaPkcs1SigPad*(hashoid: ptr cuchar, hash: ptr cuchar, hashlen: int,
                       nbitlen: uint32, x: ptr cchar): uint32 {.cdecl,
     importc: "br_rsa_pkcs1_sig_pad", header: "inner.h".}

proc brRsaPkcs1SigUnpad*(sig: ptr cuchar, siglen: int, hashoid: ptr cuchar,
                         hashlen: int, hashout: ptr cuchar): uint32 {.cdecl,
     importc: "br_rsa_pkcs1_sig_unpad", header: "inner.h".}

proc brPrngSeederSystem*(name: cstringArray): BrPrngSeeder {.cdecl,
     importc: "br_prng_seeder_system", header: "bearssl_rand.h".}

proc brHmacDrbgInit*(ctx: ptr BrHmacDrbgContext, digestClass: ptr BrHashClass,
                     seed: pointer, seedLen: int) {.
     cdecl, importc: "br_hmac_drbg_init", header: "bearssl_rand.h".}

proc brRsaKeygenGetDefault*(): BrRsaKeygen {.
     cdecl, importc: "br_rsa_keygen_get_default", header: "bearssl_rsa.h".}

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

proc brAsn1UintPrepare*(xdata: pointer, xlen: int): BrAsn1Uint {.
     cdecl, importc: "br_asn1_uint_prepare", header: "inner.h".}

proc brAsn1EncodeLength*(dest: pointer, length: int): int {.
     cdecl, importc: "br_asn1_encode_length", header: "inner.h".}

proc brAsn1EncodeUint*(dest: pointer, pp: BrAsn1Uint): int {.
     cdecl, importc: "br_asn1_encode_uint", header: "inner.h".}

proc brEncodeRsaRawDer*(dest: ptr byte, sk: ptr BrRsaPrivateKey,
                        pk: ptr BrRsaPublicKey, d: ptr byte,
                        dlength: int): int {.
     cdecl, importc: "br_encode_rsa_raw_der", header: "bearssl_x509.h".}

proc brEncodeRsaPkcs8Der*(dest: ptr byte, sk: ptr BrRsaPrivateKey,
                          pk: ptr BrRsaPublicKey, d: ptr byte,
                          dlength: int): int {.
     cdecl, importc: "br_encode_rsa_pkcs8_der", header: "bearssl_x509.h".}

proc brPemEncode*(dest: ptr byte, data: ptr byte, length: int, banner: cstring,
                  flags: cuint): int {.
     cdecl, importc: "br_pem_encode", header: "bearssl_pem.h".}

proc brPemDecoderInit*(ctx: ptr BrPemDecoderContext) {.
     cdecl, importc: "br_pem_decoder_init", header: "bearssl_pem.h".}

proc brPemDecoderPush*(ctx: ptr BrPemDecoderContext,
                       data: pointer, length: int): int {.
     cdecl, importc: "br_pem_decoder_push", header: "bearssl_pem.h".}

proc brPemDecoderSetdest*(ctx: ptr BrPemDecoderContext, dest: BrPemDecoderProc,
                          destctx: pointer) {.inline.} =
  ctx.dest = dest
  ctx.destCtx = destctx

proc brPemDecoderEvent*(ctx: ptr BrPemDecoderContext): cint {.
     cdecl, importc: "br_pem_decoder_event", header: "bearssl_pem.h".}

proc brPemDecoderName*(ctx: ptr BrPemDecoderContext): cstring =
  result = addr ctx.name[0]

proc brSkeyDecoderInit*(ctx: ptr BrSkeyDecoderContext) {.cdecl,
     importc: "br_skey_decoder_init", header: "bearssl_x509.h".}

proc brSkeyDecoderPush*(ctx: ptr BrSkeyDecoderContext,
                        data: pointer, length: int) {.cdecl,
     importc: "br_skey_decoder_push", header: "bearssl_x509.h".}

proc brSkeyDecoderLastError*(ctx: ptr BrSkeyDecoderContext): int {.inline.} =
  if ctx.err != 0:
    result = ctx.err
  else:
    if ctx.keyType == '\0':
      result = ERR_X509_TRUNCATED

proc brSkeyDecoderKeyType*(ctx: ptr BrSkeyDecoderContext): int {.inline.} =
  if ctx.err == 0:
    result = cast[int](ctx.keyType)

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

proc blobAppend(pseq: pointer, data: pointer, length: int) {.cdecl.} =
  var cseq = cast[ptr seq[byte]](pseq)
  let offset = len(cseq[])
  cseq[].setLen(offset + length)
  copyMem(addr cseq[][offset], data, length)

proc unmarshalPem*(data: string): PemList =
  ## Decode PEM encoded string.
  var ctx: BrPemDecoderContext
  result = newSeq[PemObject]()
  if len(data) > 0:
    var nlstring = "\n"
    var extranl = true

    brPemDecoderInit(addr ctx)
    var pbuf = cast[pointer](unsafeAddr data[0])
    var plen = len(data)
    var item = newSeq[byte]()

    GC_ref(item)
    var inobj: bool
    while plen > 0:
      var tlen = brPemDecoderPush(addr ctx, pbuf, plen)
      pbuf = cast[pointer](cast[uint](pbuf) + cast[uint](tlen))
      plen = plen - tlen
      let event = brPemDecoderEvent(addr ctx)
      if event == BR_PEM_BEGIN_OBJ:
        item.setLen(0)
        brPemDecoderSetdest(addr ctx, blobAppend, cast[pointer](addr item))
        inobj = true
      elif event == BR_PEM_END_OBJ:
        if inobj:
          result.add(PemObject(name: $brPemDecoderName(addr ctx), data: item))
          inobj = false
        else:
          break
      elif event == BR_PEM_ERROR:
        result.setLen(0)
        break
      if plen == 0 and extranl:
        # We add an extra newline at the end, in order to
        # support PEM files that lack the newline on their last
        # line (this is somwehat invalid, but PEM format is not
        # standardised and such files do exist in the wild, so
        # we'd better accept them).
        extranl = false
        pbuf = cast[pointer](addr nlstring[0])
        plen = 1
    if inobj:
      # PEM object was not properly finished
      result.setLen(0)
    GC_unref(item)
