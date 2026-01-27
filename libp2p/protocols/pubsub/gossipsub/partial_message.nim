# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results 

type
  MessageData* = seq[byte] 
  
  PartsMetadata* = seq[byte]

  PartialMessage* = object
  ## PartialMessage is a interface for messages that can be broken up into parts. 
  ## They can be complete, partially complete, or empty. It is up to the application to define
  ## how a message is split into parts and recombined, as well as how missing and
  ## available parts are represented.

method groupID*(m: PartialMessage): seq[byte] {.base, gcsafe, raises: [].} =
  ## An identifier to some full message. This must not depend on
  ## knowing the full message, so it can not simply be a hash of the full message.
  raiseAssert "groupID: must be implemented"

method partsMetadata*(m: PartialMessage): PartsMetadata {.base, gcsafe, raises: [].} =
  ## Returns metadata about the parts this partial message contains and
  ## possibly implicitly, the parts it wants.
  raiseAssert "partsMetadata: must be implemented"

method partialMessage*(
    m: PartialMessage, metadata: PartsMetadata
): Result[MessageData, string] {.base, gcsafe, raises: [].} =
  ## Takes in the opaque request metadata and returns a encoded partial message that 
  ## fulfills as much of the request as possible.
  ## 
  ## An empty metadata should be treated the same as a request for all parts.
  raiseAssert "partialMessage: must be implemented"
