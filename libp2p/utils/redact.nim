# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Shared representation for values that must never expose their contents
## through diagnostic formatting or generic serialization.
##
## Secret-bearing types use this marker for `$`, Chronicles, and JSON. Code
## that intentionally exports key material must use the type's explicit
## `getBytes`, `getRawBytes`, `toBytes`, or `toRawBytes` API instead.

const Redacted* = "[REDACTED]"
