# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Shared representation for values that must never expose their contents
## through diagnostic formatting or generic serialization.
##
## Secret-bearing types use this marker for `$`, Chronicles, and JSON. Code
## that intentionally exports key material must use the type's explicit
## `getBytes`, `getRawBytes`, `toBytes`, or `toRawBytes` API instead.

import std/macros
import chronicles, json_serialization/writer

const Redacted* = "[REDACTED]"

macro redactType*(T: typedesc, exported: static bool = true): untyped =
  ## Make diagnostic formatting and generic JSON serialization opaque for a
  ## secret-bearing type. Set `exported` to false for module-private types.
  let
    dollarName =
      if exported:
        postfix(ident("$"), "*")
      else:
        ident("$")
    writeValueName =
      if exported:
        postfix(ident("writeValue"), "*")
      else:
        ident("writeValue")

  result = quote do:
    proc `dollarName`(value: `T`): string =
      Redacted

    chronicles.formatIt(`T`):
      Redacted

    proc `writeValueName`(
        writer: var JsonWriter, value: `T`
    ) {.raises: [IOError].} =
      writer.writeValue(Redacted)
