# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import results

type
  GroupId* = seq[byte]
    ## Identifies a logical *full message* that partial message belongs to.
    ##
    ## The identifier must be derivable without access to the complete message
    ## (for example, it must not be a hash of the full message). Multiple
    ## PartialMessage instances that represent different parts or views of the
    ## same logical message MUST return the same GroupId.

  PartsData* = seq[byte]
    ## Encoded message data containing zero or more parts of a logical *full message*.
    ##
    ## The data may represent a complete message, a partial message, or be empty.
    ## The encoding and structure of the parts are application-defined.

  PartsMetadata* = seq[byte]
    ## Opaque, encoded metadata describing PartialMessage.
    ##
    ## This metadata MAY describe:
    ## - Parts that are currently available in a PartialMessage
    ## - Parts that are requested or missing
    ## - Or both, implicitly or explicitly
    ##
    ## The interpretation and encoding of this metadata are entirely
    ## application-defined.

  PartialMessage* = ref object of RootObj
    ## Interface for messages that can be divided into independently transferable parts.
    ##
    ## A PartialMessage may represent:
    ## - A complete message
    ## - A partially available message
    ## - No parts at all
    ##
    ## Implementations define how messages are partitioned into parts, how parts
    ## are encoded, and how availability and requests for parts are represented.

method groupId*(m: PartialMessage): GroupId {.base, gcsafe, raises: [].} =
  ## Returns the GroupId identifying the logical full message this instance
  ## belongs to.
  ##
  ## All PartialMessage instances referring to the same logical message MUST
  ## return identical GroupIds.
  raiseAssert "groupID: must be implemented"

method partsMetadata*(m: PartialMessage): PartsMetadata {.base, gcsafe, raises: [].} =
  ## Returns metadata describing the parts currently available in this
  ## PartialMessage.
  raiseAssert "partsMetadata: must be implemented"

method materializeParts*(
    m: PartialMessage, metadata: PartsMetadata
): Result[PartsData, string] {.base, gcsafe, raises: [].} =
  ## Produces encoded message data for the parts specified by `metadata`.
  ##
  ## The method SHOULD return as many of the requested parts as are available
  ## in this PartialMessage.
  ##
  ## Passing empty metadata MUST be treated as a request for all available parts.
  ##
  ## Returns:
  ## - `Ok(PartsData)` containing encoded parts on success
  ## - `Err(string)` if the request cannot be satisfied due to invalid metadata
  ##   or implementation-specific errors
  raiseAssert "partialMessage: must be implemented"
