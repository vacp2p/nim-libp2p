#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/objects.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#include <openssl/core_names.h>
#include <openssl/param_build.h>
#include <openssl/types.h>
#else
#include <openssl/rand_drbg.h>
#endif

#include "certificate.h"

#define LIBP2P_OID "1.3.6.1.4.1.53594.1.1"

struct cert_context_s {
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  OSSL_LIB_CTX *lib_ctx; /* OpenSSL library context */
  EVP_RAND_CTX *drbg;    /* DRBG context */
#else
  RAND_DRBG *drbg;
#endif
};

struct cert_key_s {
  EVP_PKEY *pkey; /* OpenSSL EVP_PKEY */
};

// Function to initialize CTR_DRBG
cert_error_t cert_init_drbg(const char *seed, size_t seed_len,
                            cert_context_t *ctx) {
  if (!seed) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Allocate context
  struct cert_context_s *c = calloc(1, sizeof(struct cert_context_s));
  if (c == NULL) {
    return CERT_ERROR_MEMORY;
  }

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  EVP_RAND_CTX *drbg = NULL;
  EVP_RAND *rand_algo = NULL;
  OSSL_LIB_CTX *libctx = OSSL_LIB_CTX_new(); // Create a new library context

  if (!libctx) {
    return CERT_ERROR_MEMORY;
  }

  rand_algo = EVP_RAND_fetch(libctx, "CTR-DRBG", NULL);
  if (!rand_algo) {
    return CERT_ERROR_DRBG_INIT;
  }

  drbg = EVP_RAND_CTX_new(rand_algo, NULL);
  EVP_RAND_free(rand_algo); // Free the algorithm object, no longer needed
  if (!drbg) {
    return CERT_ERROR_MEMORY;
  }

  OSSL_PARAM params[2];
  params[0] = OSSL_PARAM_construct_utf8_string(OSSL_DRBG_PARAM_CIPHER,
                                               "AES-256-CTR", 0);
  params[1] = OSSL_PARAM_construct_end();

  if (!EVP_RAND_CTX_set_params(drbg, params)) {
    RANDerr(0, RAND_R_ERROR_INITIALISING_DRBG);
    EVP_RAND_CTX_free(drbg);
    return CERT_ERROR_DRBG_CONFIG;
  }

  int res = EVP_RAND_instantiate(drbg, 0, 0, (const unsigned char *)seed,
                                 seed_len, NULL);
  if (res != 1) {

    EVP_RAND_CTX_free(drbg);
    return CERT_ERROR_DRBG_SEED;
  }

  c->lib_ctx = libctx;
  c->drbg = drbg;

#else
  RAND_DRBG *drbg = RAND_DRBG_new(NID_aes_256_ctr, 0, NULL);
  if (!drbg)
    return CERT_ERROR_DRBG_INIT;

  if (RAND_DRBG_instantiate(drbg, (const unsigned char *)seed, seed_len) != 1) {
    RAND_DRBG_free(drbg);
    return CERT_ERROR_DRBG_SEED;
  }

  c->drbg = drbg;
#endif

  *ctx = c;

  return CERT_SUCCESS;
}

// Function to free CTR_DRBG context resources
void cert_free_ctr_drbg(cert_context_t ctx) {
  if (ctx == NULL)
    return;

  struct cert_context_s *c = (struct cert_context_s *)ctx;
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  EVP_RAND_CTX_free(c->drbg);
  OSSL_LIB_CTX_free(c->lib_ctx);
#else
  RAND_DRBG_free(c->drbg);
#endif
  free(c);
}

// Function to ensure the libp2p OID is registered
int ensure_libp2p_oid() {
  int nid = OBJ_txt2nid(LIBP2P_OID);
  if (nid == NID_undef) {
    // OID not yet registered, create it
    nid = OBJ_create(LIBP2P_OID, "libp2p_tls", "libp2p TLS extension");
    if (!nid) {
      return CERT_ERROR_NID;
    }
  }
  return nid;
}

// Function to generate a key
cert_error_t cert_generate_key(cert_context_t ctx, cert_key_t *out) {
  unsigned char priv_key_bytes[32]; // 256 bits for secp256r1
  BIGNUM *priv_bn = NULL;
  EVP_PKEY *pkey = NULL;
  cert_error_t ret_code = CERT_SUCCESS;
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  EVP_PKEY_CTX *pctx;
#else
  EC_KEY *ec_key = NULL;
#endif

  if (ctx == NULL || out == NULL) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Allocate key structure
  struct cert_key_s *key = calloc(1, sizeof(struct cert_key_s));
  if (key == NULL) {
    return CERT_ERROR_MEMORY;
  }

// Generate random bytes for private key using our RNG
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  if (EVP_RAND_generate(ctx->drbg, priv_key_bytes, sizeof(priv_key_bytes), 0, 0,
                        NULL, 0) <= 0) {
    ret_code = CERT_ERROR_RAND;
    goto cleanup;
  }
#else
  if (RAND_DRBG_bytes(ctx->drbg, priv_key_bytes, sizeof(priv_key_bytes)) != 1) {
    ret_code = CERT_ERROR_RAND;
    goto cleanup;
  }
#endif

  // Convert bytes to BIGNUM for private key
  priv_bn = BN_bin2bn(priv_key_bytes, sizeof(priv_key_bytes), NULL);
  if (!priv_bn) {
    ret_code = CERT_ERROR_BIGNUM_CONV;
    goto cleanup;
  }

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
  if (!pctx) {
    ret_code = CERT_ERROR_KEY_GEN;
    goto cleanup;
  }

  if (EVP_PKEY_keygen_init(pctx) <= 0) {
    ret_code = CERT_ERROR_INIT_KEYGEN;
    goto cleanup;
  }

  if (EVP_PKEY_CTX_set_ec_paramgen_curve_nid(pctx, NID_X9_62_prime256v1) <= 0) {
    fprintf(stderr, "Error setting curve\n");
    ret_code = CERT_ERROR_SET_CURVE;
    goto cleanup;
  }

  // Generate the public key from the private key
  if (EVP_PKEY_keygen(pctx, &pkey) <= 0) {
    ret_code = CERT_ERROR_KEY_GEN;
    goto cleanup;
  }
#else
  // Create EC key from random bytes
  ec_key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
  if (!ec_key) {
    ret_code = CERT_ERROR_ECKEY_GEN;
    goto cleanup;
  }

  // Set private key and compute public key
  if (!EC_KEY_set_private_key(ec_key, priv_bn)) {
    ret_code = CERT_ERROR_SET_KEY;
    goto cleanup;
  }

  // Generate the public key from the private key
  if (!EC_KEY_generate_key(ec_key)) {
    ret_code = CERT_ERROR_KEY_GEN;
    goto cleanup;
  }

  // Convert EC_KEY to EVP_PKEY
  pkey = EVP_PKEY_new();
  if (!pkey || !EVP_PKEY_set1_EC_KEY(pkey, ec_key)) {
    ret_code = CERT_ERROR_EVP_PKEY_EC_KEY;
    goto cleanup;
  }
#endif

  key->pkey = pkey;
  *out = key;

cleanup:
  OPENSSL_cleanse(priv_key_bytes, sizeof(priv_key_bytes));
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  if (pctx)
    EVP_PKEY_CTX_free(pctx);
#else
  if (ec_key)
    EC_KEY_free(ec_key);
#endif
  if (priv_bn)
    BN_free(priv_bn);
  if (ret_code != CERT_SUCCESS) {
    if (pkey)
      EVP_PKEY_free(pkey);
    free(key);
    *out = NULL;
  }

  return ret_code;
}

int init_cert_buffer(cert_buffer **buffer, const unsigned char *src_data,
                     size_t data_len) {
  if (!buffer) {
    return CERT_ERROR_NULL_PARAM;
  }

  *buffer = (cert_buffer *)malloc(sizeof(cert_buffer));
  if (!*buffer) {
    return CERT_ERROR_MEMORY;
  }
  memset(*buffer, 0, sizeof(cert_buffer));

  (*buffer)->data = (unsigned char *)malloc(data_len);
  if (!(*buffer)->data) {
    free(*buffer);
    *buffer = NULL;
    return CERT_ERROR_MEMORY;
  }

  memcpy((*buffer)->data, src_data, data_len);
  (*buffer)->len = data_len;

  return CERT_SUCCESS;
}

// Function to generate a self-signed X.509 certificate with custom extension
cert_error_t cert_generate(cert_context_t ctx, cert_key_t key,
                           cert_buffer **out, cert_buffer *signature,
                           cert_buffer *ident_pubk, const char *cn,
                           const char *validFrom, const char *validTo,
                           cert_format_t format) {
  X509 *x509 = NULL;
  BIO *bio = NULL;
  BUF_MEM *bptr = NULL;
  X509_EXTENSION *ex = NULL;
  BIGNUM *serial_bn = NULL;
  X509_NAME *name = NULL;
  X509_EXTENSION *ku_ex = NULL;
  ASN1_BIT_STRING *usage = NULL;
  ASN1_OCTET_STRING *oct_sign = NULL;
  ASN1_OCTET_STRING *oct_pubk = NULL;
  ASN1_OCTET_STRING *ext_oct = NULL;
  ASN1_TIME *start_time = NULL;
  ASN1_TIME *end_time = NULL;
  unsigned char *seq_der = NULL;
  int ret = 0;

  cert_error_t ret_code = CERT_SUCCESS;

  if (ctx == NULL || key == NULL) {
    ret_code = CERT_ERROR_NULL_PARAM;
    goto cleanup;
  }

  // Get the EVP_PKEY from our opaque key structure
  EVP_PKEY *pkey = ((struct cert_key_s *)key)->pkey;
  if (pkey == NULL) {
    ret_code = CERT_ERROR_NULL_PARAM;
    goto cleanup;
  }

  // Allocate result structure
  *out = (cert_buffer *)malloc(sizeof(cert_buffer));
  if (!*out) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }
  memset(*out, 0, sizeof(cert_buffer));

  // Create X509 certificate
  x509 = X509_new();
  if (!x509) {
    ret_code = CERT_ERROR_CERT_GEN;
    goto cleanup;
  }

  // Set version to X509v3
  if (!X509_set_version(x509, 2)) {
    ret_code = CERT_ERROR_X509_VER;
    goto cleanup;
  }

  // Set random serial number
  serial_bn = BN_new();
  if (!serial_bn) {
    ret_code = CERT_ERROR_BIGNUM_GEN;
    goto cleanup;
  }

  unsigned char serial_bytes[20]; // Adjust size as needed
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  if (EVP_RAND_generate(ctx->drbg, serial_bytes, sizeof(serial_bytes), 0, 0,
                        NULL, 0) <= 0) {
    ret_code = CERT_ERROR_RAND;
    goto cleanup;
  }
#else
  if (RAND_DRBG_bytes(ctx->drbg, serial_bytes, sizeof(serial_bytes)) != 1) {
    ret_code = CERT_ERROR_RAND;
    goto cleanup;
  }
#endif

  if (!BN_bin2bn(serial_bytes, sizeof(serial_bytes), serial_bn)) {
    ret_code = CERT_ERROR_BIGNUM_CONV;
    goto cleanup;
  }

  if (!BN_to_ASN1_INTEGER(serial_bn, X509_get_serialNumber(x509))) {
    ret_code = CERT_ERROR_SERIAL_WRITE;
    goto cleanup;
  }

  // Set subject and issuer using the provided cn
  name = X509_NAME_new();
  if (!name) {
    ret_code = CERT_ERROR_X509_NAME;
    goto cleanup;
  }
  if (!X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                  (const unsigned char *)cn, -1, -1, 0)) {
    ret_code = CERT_ERROR_X509_CN;
    goto cleanup;
  }
  if (!X509_set_subject_name(x509, name)) {
    ret_code = CERT_ERROR_X509_SUBJECT;
    goto cleanup;
  }
  if (!X509_set_issuer_name(x509, name)) {
    ret_code = CERT_ERROR_X509_ISSUER;
    goto cleanup;
  }

  // Set validity period
  start_time = ASN1_TIME_new();
  end_time = ASN1_TIME_new();
  if (!start_time || !end_time) {
    ret_code = CERT_ERROR_AS1_TIME_GEN;
    goto cleanup;
  }
  if (!ASN1_TIME_set_string(start_time, validFrom) ||
      !ASN1_TIME_set_string(end_time, validTo)) {
    ret_code = CERT_ERROR_VALIDITY_PERIOD;
    goto cleanup;
  }
  if (!X509_set1_notBefore(x509, start_time) ||
      !X509_set1_notAfter(x509, end_time)) {
    ret_code = CERT_ERROR_VALIDITY_PERIOD;
    goto cleanup;
  }

  // Set public key
  if (!X509_set_pubkey(x509, pkey)) {
    ret_code = CERT_ERROR_PUBKEY_SET;
    goto cleanup;
  }

  // Add custom extension
  int nid = ensure_libp2p_oid();
  if (nid <= 0) {
    ret_code = nid;
    goto cleanup;
  }

  unsigned char *p;
  int seq_len, total_len;

  // Allocate and initialize ASN1_OCTET_STRING objects
  oct_pubk = ASN1_OCTET_STRING_new();
  if (!oct_pubk) {
    ret_code = CERT_ERROR_AS1_OCTET;
    goto cleanup;
  }

  oct_sign = ASN1_OCTET_STRING_new();
  if (!oct_sign) {
    ret_code = CERT_ERROR_AS1_OCTET;
    goto cleanup;
  }

  if (!ASN1_OCTET_STRING_set(oct_pubk, ident_pubk->data, ident_pubk->len)) {
    ret_code = CERT_ERROR_EXTENSION_DATA;
    goto cleanup;
  }

  if (!ASN1_OCTET_STRING_set(oct_sign, signature->data, signature->len)) {
    ret_code = CERT_ERROR_EXTENSION_DATA;
    goto cleanup;
  }

  // Calculate DER-encoded lengths of the OCTET STRINGs
  int oct_pubk_len = i2d_ASN1_OCTET_STRING(oct_pubk, NULL);
  int oct_sign_len = i2d_ASN1_OCTET_STRING(oct_sign, NULL);
  seq_len = oct_pubk_len + oct_sign_len;

  // Compute the exact required length for the SEQUENCE
  total_len = ASN1_object_size(1, seq_len, V_ASN1_SEQUENCE);

  // Allocate the exact required space
  seq_der = OPENSSL_malloc(total_len);
  if (!seq_der) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }

  // Encode the sequence. p is moved fwd as it is written
  p = seq_der;
  ASN1_put_object(&p, 1, seq_len, V_ASN1_SEQUENCE, V_ASN1_UNIVERSAL);
  i2d_ASN1_OCTET_STRING(oct_pubk, &p);
  i2d_ASN1_OCTET_STRING(oct_sign, &p);

  // Wrap the encoded sequence in an ASN1_OCTET_STRING
  ext_oct = ASN1_OCTET_STRING_new();
  if (!ext_oct) {
    ret_code = CERT_ERROR_AS1_OCTET;
    goto cleanup;
  }

  if (!ASN1_OCTET_STRING_set(ext_oct, seq_der, total_len)) {
    ret_code = CERT_ERROR_EXTENSION_DATA;
    goto cleanup;
  }

  // Create extension with the octet string
  ex = X509_EXTENSION_create_by_NID(NULL, nid, 0, ext_oct);
  if (!ex) {
    ret_code = CERT_ERROR_EXTENSION_GEN;
    goto cleanup;
  }

  // Add extension to certificate
  if (!X509_add_ext(x509, ex, -1)) {
    ret_code = CERT_ERROR_EXTENSION_ADD;
    goto cleanup;
  }

  /*
  // Add Key Usage extension
  usage = ASN1_BIT_STRING_new();
  if (!usage) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }

  // Set bits for DIGITAL_SIGNATURE (bit 0) and KEY_ENCIPHERMENT (bit 2)
  if (!ASN1_BIT_STRING_set_bit(usage, 0, 1) ||
      !ASN1_BIT_STRING_set_bit(usage, 2, 1)) {
    ret_code = CERT_ERROR_EXTENSION_DATA;
    goto cleanup;
  }
  */

  // Create Key Usage extension
  /*ku_ex = X509_EXTENSION_create_by_NID(NULL, NID_key_usage, 1,
                                       usage); // 1 for  critical
  if (!ku_ex) {
    ret_code = CERT_ERROR_EXTENSION_GEN;
    goto cleanup;
  }

  // Add extension to certificate
  if (!X509_add_ext(x509, ku_ex, -1)) {
    ret_code = CERT_ERROR_EXTENSION_ADD;
    goto cleanup;
  }*/

  // Sign the certificate with SHA256
  if (!X509_sign(x509, pkey, EVP_sha256())) {
    ret_code = CERT_ERROR_SIGN;
    goto cleanup;
  }

  // Convert to requested format (DER or PEM)
  bio = BIO_new(BIO_s_mem());
  if (!bio) {
    ret_code = CERT_ERROR_BIO_GEN;
    goto cleanup;
  }

  if (format == CERT_FORMAT_DER) {
    ret = i2d_X509_bio(bio, x509);
  } else { // PEM format
    ret = PEM_write_bio_X509(bio, x509);
  }

  if (!ret) {
    ret_code = CERT_ERROR_BIO_WRITE;
    goto cleanup;
  }

  BIO_get_mem_ptr(bio, &bptr);
  (*out)->data = (unsigned char *)malloc(bptr->length);
  if (!(*out)->data) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }
  memcpy((*out)->data, bptr->data, bptr->length);
  (*out)->len = bptr->length;

cleanup:
  if (bio)
    BIO_free(bio);
  if (ex)
    X509_EXTENSION_free(ex);
  // if (usage)
  //  ASN1_BIT_STRING_free(usage);
  if (ku_ex)
    X509_EXTENSION_free(ku_ex);
  if (oct_sign)
    ASN1_OCTET_STRING_free(oct_sign);
  if (oct_pubk)
    ASN1_OCTET_STRING_free(oct_pubk);
  if (ext_oct)
    ASN1_OCTET_STRING_free(ext_oct);
  if (seq_der)
    OPENSSL_free(seq_der);
  if (serial_bn)
    BN_free(serial_bn);
  if (name)
    X509_NAME_free(name);
  if (x509)
    X509_free(x509);
  if (start_time)
    ASN1_TIME_free(start_time);
  if (end_time)
    ASN1_TIME_free(end_time);

  if (ret_code != CERT_SUCCESS && (*out)) {
    if ((*out)->data)
      free((*out)->data);
    free((*out));
    *out = NULL;
  }

  return ret_code;
}

// Function to parse a certificate and extract custom extension and public key
cert_error_t cert_parse(cert_buffer *cert, cert_format_t format,
                        cert_parsed **out) {
  X509 *x509 = NULL;
  BIO *bio = NULL;
  int extension_index;
  X509_EXTENSION *ex = NULL;
  ASN1_OCTET_STRING *ext_data = NULL;
  ASN1_SEQUENCE_ANY *seq = NULL;
  ASN1_OCTET_STRING *oct1 = NULL;
  ASN1_OCTET_STRING *oct2 = NULL;
  EVP_PKEY *pkey = NULL;
  unsigned char *pubkey_buf = NULL;
  cert_error_t ret_code;

  // Allocate result structure
  *out = (cert_parsed *)malloc(sizeof(cert_parsed));
  if (!*out) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }
  memset(*out, 0, sizeof(cert_parsed));

  // Create BIO from memory
  bio = BIO_new_mem_buf(cert->data, cert->len);
  if (!bio) {
    ret_code = CERT_ERROR_BIO_GEN;
    goto cleanup;
  }

  // Parse certificate based on format
  if (format == 0) { // DER format
    x509 = d2i_X509_bio(bio, NULL);
  } else { // PEM format
    x509 = PEM_read_bio_X509(bio, NULL, NULL, NULL);
  }

  if (!x509) {
    ret_code = CERT_ERROR_X509_READ;
    goto cleanup;
  }

  // Find custom extension by OID - use the existing OID or create it if needed
  int nid = ensure_libp2p_oid();
  if (!nid) {
    goto cleanup;
  }

  extension_index = X509_get_ext_by_NID(x509, nid, -1);
  if (extension_index < 0) {
    ret_code = CERT_ERROR_EXTENSION_NOT_FOUND;
    goto cleanup;
  }

  // Get extension
  ex = X509_get_ext(x509, extension_index);
  if (!ex) {
    ret_code = CERT_ERROR_EXTENSION_GET;
    goto cleanup;
  }

  // Get extension data
  ext_data = X509_EXTENSION_get_data(ex);
  if (!ext_data) {
    ret_code = CERT_ERROR_EXTENSION_DATA;
    goto cleanup;
  }

  // Point to the data
  const unsigned char *p;
  p = ASN1_STRING_get0_data(ext_data);

  // Decode the SEQUENCE
  seq = d2i_ASN1_SEQUENCE_ANY(NULL, &p, ASN1_STRING_length(ext_data));
  if (!seq) {
    ret_code = CERT_ERROR_DECODE_SEQUENCE;
    goto cleanup;
  }

  // Check if we have exactly two items in the sequence
  if (sk_ASN1_TYPE_num(seq) != 2) {
    ret_code = CERT_ERROR_NOT_ENOUGH_SEQ_ELEMS;
    goto cleanup;
  }

  // Get the first octet string
  ASN1_TYPE *type1 = sk_ASN1_TYPE_value(seq, 0);
  if (type1->type != V_ASN1_OCTET_STRING) {
    ret_code = CERT_ERROR_NOT_OCTET_STR;
    goto cleanup;
  }
  oct1 = type1->value.octet_string;

  // Get the second octet string
  ASN1_TYPE *type2 = sk_ASN1_TYPE_value(seq, 1);
  if (type2->type != V_ASN1_OCTET_STRING) {
    ret_code = CERT_ERROR_NOT_OCTET_STR;
    goto cleanup;
  }
  oct2 = type2->value.octet_string;

  ret_code =
      init_cert_buffer(&((*out)->ident_pubk), ASN1_STRING_get0_data(oct1),
                       ASN1_STRING_length(oct1));
  if (ret_code != 0) {
    goto cleanup;
  }

  ret_code = init_cert_buffer(&((*out)->signature), ASN1_STRING_get0_data(oct2),
                              ASN1_STRING_length(oct2));
  if (ret_code != 0) {
    goto cleanup;
  }

  // Get public key
  pkey = X509_get_pubkey(x509);
  if (!pkey) {
    ret_code = CERT_ERROR_PUBKEY_GET;
    goto cleanup;
  }

  // Get public key length
  int pubkey_len = i2d_PUBKEY(pkey, NULL);
  if (pubkey_len <= 0) {
    ret_code = CERT_ERROR_PUBKEY_DER_LEN;
    goto cleanup;
  }

  pubkey_buf = (unsigned char *)malloc(pubkey_len);
  if (!pubkey_buf) {
    ret_code = CERT_ERROR_MEMORY;
    goto cleanup;
  }

  unsigned char *temp = pubkey_buf;
  if (i2d_PUBKEY(pkey, &temp) <= 0) {
    ret_code = CERT_ERROR_PUBKEY_DER_CONV;
    goto cleanup;
  }

  ret_code = init_cert_buffer(&(*out)->cert_pubkey, pubkey_buf, pubkey_len);
  if (ret_code != CERT_SUCCESS) {
    goto cleanup;
  }

  const ASN1_TIME *not_before = X509_get0_notBefore(x509);
  if (not_before) {
    // Convert ASN1_TIME to a more usable format
    char *not_before_str = NULL;
    BIO *bio_nb = BIO_new(BIO_s_mem());
    if (bio_nb) {
      if (ASN1_TIME_print(bio_nb, not_before)) {
        size_t len = BIO_ctrl_pending(bio_nb);
        not_before_str = malloc(len + 1);
        if (not_before_str) {
          BIO_read(bio_nb, not_before_str, len);
          not_before_str[len] = '\0';

          // Store in the output structure
          (*out)->valid_from = not_before_str;
        }
      }
      BIO_free(bio_nb);
    } else {
      ret_code = CERT_ERROR_MEMORY;
      goto cleanup;
    }
  }

  const ASN1_TIME *not_after = X509_get0_notAfter(x509);
  if (not_after) {
    // Convert ASN1_TIME to a more usable format
    char *not_after_str = NULL;
    BIO *bio_na = BIO_new(BIO_s_mem());
    if (bio_na) {
      if (ASN1_TIME_print(bio_na, not_after)) {
        size_t len = BIO_ctrl_pending(bio_na);
        not_after_str = malloc(len + 1);
        if (not_after_str) {
          BIO_read(bio_na, not_after_str, len);
          not_after_str[len] = '\0';

          // Store in the output structure
          (*out)->valid_to = not_after_str;
        }
      }
      BIO_free(bio_na);
    }
  }

  ret_code = CERT_SUCCESS;

cleanup:
  if (pkey)
    EVP_PKEY_free(pkey);
  if (x509)
    X509_free(x509);
  if (bio)
    BIO_free(bio);
  if (pubkey_buf)
    free(pubkey_buf);
  if (ret_code != CERT_SUCCESS && (*out)) {
    cert_free_parsed(*out);
    out = NULL;
  }

  return ret_code;
}

cert_error_t cert_serialize_privk(cert_key_t key, cert_buffer **out,
                                  cert_format_t format) {
  BIO *bio = NULL;
  BUF_MEM *bptr = NULL;
  int ret;
  cert_error_t ret_code = CERT_SUCCESS;

  if (key == NULL || out == NULL) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Get the EVP_PKEY from our opaque key structure
  EVP_PKEY *pkey = ((struct cert_key_s *)key)->pkey;
  if (!pkey) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Create memory BIO
  bio = BIO_new(BIO_s_mem());
  if (!bio) {
    ret_code = CERT_ERROR_BIO_GEN;
    goto cleanup;
  }

  if (format == CERT_FORMAT_DER) {
    // Write key in DER format to BIO
    ret = i2d_PrivateKey_bio(bio, pkey);
    if (!ret) {
      ret_code = CERT_ERROR_BIO_WRITE;
      goto cleanup;
    }
  } else {
    // No encryption is used (NULL cipher, NULL password)
    ret = PEM_write_bio_PrivateKey(bio, pkey, NULL, NULL, 0, NULL, NULL);
    if (!ret) {
      ret_code = CERT_ERROR_BIO_WRITE;
      goto cleanup;
    }
  }
  // Get the data from BIO
  BIO_get_mem_ptr(bio, &bptr);

  ret = init_cert_buffer(out, (const unsigned char *)bptr->data, bptr->length);
  if (ret != CERT_SUCCESS) {
    goto cleanup;
  }

cleanup:
  if (bio)
    BIO_free(bio);

  if (ret_code != CERT_SUCCESS && *out) {
    if ((*out)->data)
      free((*out)->data);
    free(*out);
    *out = NULL;
  }

  return ret_code;
}

cert_error_t cert_serialize_pubk(cert_key_t key, cert_buffer **out,
                                 cert_format_t format) {
  BIO *bio = NULL;
  BUF_MEM *bptr = NULL;
  int ret;
  cert_error_t ret_code = CERT_SUCCESS;

  if (key == NULL || out == NULL) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Get the EVP_PKEY from our opaque key structure
  EVP_PKEY *pkey = ((struct cert_key_s *)key)->pkey;
  if (!pkey) {
    return CERT_ERROR_NULL_PARAM;
  }

  // Create memory BIO
  bio = BIO_new(BIO_s_mem());
  if (!bio) {
    ret_code = CERT_ERROR_BIO_GEN;
    goto cleanup;
  }

  if (format == CERT_FORMAT_DER) {
    // Write key in DER format to BIO
    ret = i2d_PUBKEY_bio(bio, pkey);
    if (!ret) {
      unsigned long err = ERR_get_error();
      printf("openssl err: %s\n", ERR_error_string(err, NULL));

      ret_code = CERT_ERROR_BIO_WRITE;
      goto cleanup;
    }
  } else {
    ret = PEM_write_bio_PUBKEY(bio, pkey);
    if (!ret) {
      ret_code = CERT_ERROR_BIO_WRITE;
      goto cleanup;
    }
  }
  // Get the data from BIO
  BIO_get_mem_ptr(bio, &bptr);

  ret = init_cert_buffer(out, (const unsigned char *)bptr->data, bptr->length);
  if (ret != CERT_SUCCESS) {
    goto cleanup;
  }

cleanup:
  if (bio)
    BIO_free(bio);

  if (ret_code != CERT_SUCCESS && *out) {
    if ((*out)->data)
      free((*out)->data);
    free(*out);
    *out = NULL;
  }

  return ret_code;
}

void cert_free_buffer(cert_buffer *buffer) {
  if (buffer) {
    if (buffer->data)
      free(buffer->data);
    free(buffer);
  }
}

// Function to free the parsed certificate struct
void cert_free_parsed(cert_parsed *cert) {
  if (cert) {
    if (cert->cert_pubkey)
      cert_free_buffer(cert->cert_pubkey);
    if (cert->ident_pubk)
      cert_free_buffer(cert->ident_pubk);
    if (cert->signature)
      cert_free_buffer(cert->signature);
    if (cert->valid_from)
      free(cert->valid_from);
    if (cert->valid_to)
      free(cert->valid_to);

    free(cert);
  }
}

// Function to free key resources
void cert_free_key(cert_key_t key) {
  if (key == NULL)
    return;

  struct cert_key_s *k = (struct cert_key_s *)key;
  EVP_PKEY_free(k->pkey);
  free(k);
}