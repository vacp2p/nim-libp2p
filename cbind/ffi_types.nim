# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# FFI Types and Utilities
#
# This file defines the core types and utilities for the library's foreign
# function interface (FFI), enabling interoperability with external code.

################################################################################
### Exported types

type Libp2pCallback* = proc(
  callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

type
  RetCode* {.size: sizeof(cint).}= enum
    RET_OK = 0,
    RET_ERR = 1,
    RET_MISSING_CALLBACK = 2


### End of exported types
################################################################################

################################################################################
### FFI utils

template foreignThreadGc*(body: untyped) =
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()

  body

  when declared(tearDownForeignThreadGc):
    tearDownForeignThreadGc()

type onDone* = proc()

### End of FFI utils
################################################################################
