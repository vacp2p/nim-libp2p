# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/macros

template compilesOr*(a, b: untyped): untyped =
  when compiles(a): a else: b

macro includeFile*(file: static[string]): untyped =
  let res = newStmtList()

  try:
    res.add(nnkIncludeStmt.newTree(newLit(file)))
  except ValueError as e:
    raiseAssert("Failed to include file: " & file & ", error: " & e.msg)

  return res
