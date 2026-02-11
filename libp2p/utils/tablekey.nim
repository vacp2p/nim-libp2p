# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[tables, hashes]

const keyDelimiter = "::"

type TableKey* = object of RootObj
  key*: string

proc `==`(a, b: TableKey): bool =
  a.key == b.key

proc hash(x: TableKey): Hash =
  hash(x.key)

proc makeKey*(T: typedesc[TableKey], args: varargs[string, `$`]): string =
  var k: string
  for i, arg in args:
    if i > 0:
      k.add(keyDelimiter)
    k.add(arg)
  return k
