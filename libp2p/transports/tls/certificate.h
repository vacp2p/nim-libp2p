#ifndef LIBP2P_CERT_H
#define LIBP2P_CERT_H

#include <stddef.h>
#include <stdint.h>

typedef struct cert_context_s *cert_context_t;

typedef struct cert_key_s *cert_key_t;

typedef int32_t cert_error_t;

#define CERT_SUCCESS 0
#define CERT_ERROR_NULL_PARAM -1
#define CERT_ERROR_MEMORY -2
#define CERT_ERROR_DRBG_INIT -3
#define CERT_ERROR_DRBG_CONFIG -4
#define CERT_ERROR_DRBG_SEED -5
#define CERT_ERROR_KEY_GEN -6
#define CERT_ERROR_CERT_GEN -7
#define CERT_ERROR_EXTENSION_GEN -8
#define CERT_ERROR_EXTENSION_ADD -9
#define CERT_ERROR_EXTENSION_DATA -10
#define CERT_ERROR_BIO_GEN -11
#define CERT_ERROR_SIGN -12
#define CERT_ERROR_ENCODING -13
#define CERT_ERROR_PARSE -14
#define CERT_ERROR_RAND -15
#define CERT_ERROR_ECKEY_GEN -16
#define CERT_ERROR_BIGNUM_CONV -17
#define CERT_ERROR_SET_KEY -18
#define CERT_ERROR_VALIDITY_PERIOD -19
#define CERT_ERROR_BIO_WRITE -20
#define CERT_ERROR_SERIAL_WRITE -21
#define CERT_ERROR_EVP_PKEY_EC_KEY -22
#define CERT_ERROR_X509_VER -23
#define CERT_ERROR_BIGNUM_GEN -24
#define CERT_ERROR_X509_NAME -25
#define CERT_ERROR_X509_CN -26
#define CERT_ERROR_X509_SUBJECT -27
#define CERT_ERROR_X509_ISSUER -28
#define CERT_ERROR_AS1_TIME_GEN -29
#define CERT_ERROR_PUBKEY_SET -30
#define CERT_ERROR_AS1_OCTET -31
#define CERT_ERROR_X509_READ -32
#define CERT_ERROR_PUBKEY_GET -33
#define CERT_ERROR_EXTENSION_NOT_FOUND -34
#define CERT_ERROR_EXTENSION_GET -35
#define CERT_ERROR_DECODE_SEQUENCE -36
#define CERT_ERROR_NOT_ENOUGH_SEQ_ELEMS -37
#define CERT_ERROR_NOT_OCTET_STR -38
#define CERT_ERROR_NID -39
#define CERT_ERROR_PUBKEY_DER_LEN -40
#define CERT_ERROR_PUBKEY_DER_CONV -41
#define CERT_ERROR_INIT_KEYGEN -42
#define CERT_ERROR_SET_CURVE -43

typedef enum { CERT_FORMAT_DER = 0, CERT_FORMAT_PEM = 1 } cert_format_t;

/* Buffer structure for raw key data */
typedef struct {
  unsigned char *data; /*  data buffer */
  size_t len;          /* Length of data */
} cert_buffer;

/* Struct to hold the parsed certificate data */
typedef struct {
  cert_buffer *signature;
  cert_buffer *ident_pubk;
  cert_buffer *cert_pubkey;
  char *valid_from;
  char *valid_to;
} cert_parsed;

/**
 * Initialize the CTR-DRBG for cryptographic operations
 * This function creates and initializes a CTR-DRBG context using
 * the provided seed for entropy. The DRBG is configured to use
 * AES-256-CTR as the underlying cipher.
 *
 * @param seed A null-terminated string used to seed the DRBG. Must not be NULL.
 * @param ctx Pointer to a context pointer that will be allocated and
 * initialized. The caller is responsible for eventually freeing this context
 * with the appropriate cleanup function.
 *
 * @return CERT_SUCCESS on successful initialization, an error code otherwise
 */
cert_error_t cert_init_drbg(const char *seed, size_t seed_len,
                            cert_context_t *ctx);

/**
 * Generate an EC key pair for use with certificates
 *
 * @param ctx Context pointer obtained from `cert_init_drbg`
 * @param out Pointer to store the generated key
 *
 * @return CERT_SUCCESS on successful execution, an error code otherwise
 */
cert_error_t cert_generate_key(cert_context_t ctx, cert_key_t *out);

/**
 * Serialize a key's private key to a format
 *
 * @param key The key to export
 * @param out Pointer to a buffer structure that will be populated with the key
 * @param format output format
 *
 * @return CERT_SUCCESS on successful execution, an error code otherwise
 */
cert_error_t cert_serialize_privk(cert_key_t key, cert_buffer **out,
                                  cert_format_t format);

/**
 * Serialize a key's public key to a format
 *
 * @param key The key to export
 * @param out Pointer to a buffer structure that will be populated with the key
 * @param format output format
 *
 * @return CERT_SUCCESS on successful execution, an error code otherwise
 */
cert_error_t cert_serialize_pubk(cert_key_t key, cert_buffer **out,
                                 cert_format_t format);

/**
 * Generate a self-signed X.509 certificate with libp2p extension
 *
 * @param ctx Context pointer obtained from `cert_init_drbg`
 * @param key Key to use
 * @param out Pointer to a buffer that will be populated with a certificate
 * @param signature buffer that contains a signature
 * @param ident_pubk buffer that contains the bytes of an identity pubk
 * @param common_name Common name to use for the certificate subject/issuer
 * @param validFrom Date from which certificate is issued
 * @param validTo Date to which certificate is issued
 * @param format Certificate format
 *
 * @return CERT_SUCCESS on successful execution, an error code otherwise
 */
cert_error_t cert_generate(cert_context_t ctx, cert_key_t key,
                           cert_buffer **out, cert_buffer *signature,
                           cert_buffer *ident_pubk, const char *cn,
                           const char *validFrom, const char *validTo,
                           cert_format_t format);

/**
 * Parse a certificate to extract the custom extension and public key
 *
 * @param cert            Buffer containing the certificate data
 * @param format          Certificate format
 * @param cert_parsed     Pointer to a structure containing the parsed
 * certificate data.
 *
 * @return CERT_SUCCESS on successful execution, an error code otherwise
 */
cert_error_t cert_parse(cert_buffer *cert, cert_format_t format,
                        cert_parsed **out);

/**
 * Free all resources associated with a CTR-DRBG context
 *
 * @param ctx The context to free
 */
void cert_free_ctr_drbg(cert_context_t ctx);

/**
 * Free memory allocated for a parsed certificate
 *
 * @param cert  Pointer to the parsed certificate structure
 */
void cert_free_parsed(cert_parsed *cert);

/**
 * Free all resources associated with a key
 *
 * @param key The key to free
 */
void cert_free_key(cert_key_t key);

/**
 * Free memory allocated for a buffer
 *
 * @param buffer Pointer to the buffer structure
 */
void cert_free_buffer(cert_buffer *buffer);

#endif /* LIBP2P_CERT_H */