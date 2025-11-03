# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import metrics

declarePublicCounter mix_messages_recvd, "number of mix messages received", ["type"]

declarePublicCounter mix_messages_forwarded,
  "number of mix messages forwarded", ["type"]

declarePublicCounter mix_messages_error,
  "number of mix messages failed processing", ["type", "error"]

declarePublicGauge mix_pool_size, "number of nodes in the pool"
