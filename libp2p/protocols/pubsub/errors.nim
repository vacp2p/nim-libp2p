# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import ../../errors

type
  ValidationResult* {.pure.} = enum
    Accept
    Reject
    Ignore

  MessageTooLargeError* = object of LPError
    ## Raised when an application publishes a message whose encoded size
    ## exceeds `maxMessageSize`.
