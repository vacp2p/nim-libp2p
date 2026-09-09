# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronicles, json_serialization/writer
import chronos/streams/tlsstream
import ./redact

redactType(TLSPrivateKey)
