when defined(macosx):
  {.passl: "-L/opt/homebrew/opt/openssl@3/lib -lcrypto".}
  {.passc: "-I/opt/homebrew/opt/openssl@3/include".}
else:
  {.passl: "-lcrypto".}

{.compile: "./certificate.c".}

type
  cert_error_t* = int32

  cert_format_t* {.size: sizeof(cuint).} = enum
    CERT_FORMAT_DER = 0
    CERT_FORMAT_PEM = 1

  cert_buffer* {.pure, inheritable, bycopy.} = object
    data*: ptr uint8
    length*: csize_t

  cert_parsed* {.pure, inheritable, bycopy.} = object
    signature*: ptr cert_buffer
    ident_pubk*: ptr cert_buffer
    cert_pbuk*: ptr cert_buffer
    valid_from*: cstring
    valid_to*: cstring

  cert_context_s* = object

  cert_key_s* = object

  cert_context_t* = ptr cert_context_s

  cert_key_t* = ptr cert_key_s

const CERT_SUCCESS* = 0

proc cert_init_drbg*(
  seed: cstring, seed_len: csize_t, ctx: ptr cert_context_t
): cert_error_t {.cdecl, importc: "cert_init_drbg".}

proc cert_generate_key*(
  ctx: cert_context_t, out_arg: ptr cert_key_t
): cert_error_t {.cdecl, importc: "cert_generate_key".}

proc cert_serialize_privk*(
  key: cert_key_t, out_arg: ptr ptr cert_buffer, format: cert_format_t
): cert_error_t {.cdecl, importc: "cert_serialize_privk".}

proc cert_serialize_pubk*(
  key: cert_key_t, out_arg: ptr ptr cert_buffer, format: cert_format_t
): cert_error_t {.cdecl, importc: "cert_serialize_pubk".}

proc cert_generate*(
  ctx: cert_context_t,
  key: cert_key_t,
  out_arg: ptr ptr cert_buffer,
  signature: ptr cert_buffer,
  ident_pubk: ptr cert_buffer,
  cn: cstring,
  validFrom: cstring,
  validTo: cstring,
  format: cert_format_t,
): cert_error_t {.cdecl, importc: "cert_generate".}

proc cert_parse*(
  cert: ptr cert_buffer, format: cert_format_t, out_arg: ptr ptr cert_parsed
): cert_error_t {.cdecl, importc: "cert_parse".}

proc cert_free_ctr_drbg*(
  ctx: cert_context_t
): void {.cdecl, importc: "cert_free_ctr_drbg".}

proc cert_free_key*(key: cert_key_t): void {.cdecl, importc: "cert_free_key".}

proc cert_free_buffer*(
  buffer: ptr cert_buffer
): void {.cdecl, importc: "cert_free_buffer".}

proc cert_free_parsed*(
  cert: ptr cert_parsed
): void {.cdecl, importc: "cert_free_parsed".}
