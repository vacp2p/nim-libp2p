# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronicles, json_serialization/writer
import chronos/streams/tlsstream
import ./redact

proc `$`*(key: TLSPrivateKey): string =
  ## Return a diagnostic representation without exposing private key material.
  Redacted

chronicles.formatIt(TLSPrivateKey):
  Redacted

proc writeValue*(
    writer: var JsonWriter, key: TLSPrivateKey
) {.raises: [IOError].} =
  writer.writeValue(Redacted)
