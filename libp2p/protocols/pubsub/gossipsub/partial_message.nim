# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

type PartialMessage* = object
  ## PartialMessage is a message that can be broken up into parts. It can be
  ## complete, partially complete, or empty. It is up to the application to define
  ## how a message is split into parts and recombined, as well as how missing and
  ## available parts are represented.

method groupID*(m: PartialMessage): seq[byte] {.base, gcsafe.} =
  raiseAssert "groupID needs to be implemented"

method partsMetadata*(m: PartialMessage): seq[byte] {.base, gcsafe.} =
  raiseAssert "partsMetadata needs to be implemented"

method partialMessage*(m: PartialMessage): seq[byte] {.base, gcsafe.} =
  raiseAssert "partialMessage needs to be implemented"
