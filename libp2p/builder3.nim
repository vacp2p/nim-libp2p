# Nim-Libp2p
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [Defect].}

import std/[tables, macros, sequtils]

type
  GenHolder = ref object of RootObj

  Holder[T] = ref object of GenHolder
    value: T

  TypeTable = object
    table: Table[string, GenHolder]

proc contains[T](tt: TypeTable, typ: type[T]): bool =
  tt.table.contains($typ)

proc contains(tt: TypeTable, typ: string): bool =
  tt.table.contains(typ)

proc `[]`[T](tt: TypeTable, typ: type[T]): T =
  let holder = Holder[T](tt.table.getOrDefault($typ))
  if holder.isNil:
    default(T)
  else:
    holder.value

proc `[]=`[T](tt: var TypeTable, typ: type[T], val: T) =
  let holder = Holder[T](tt.table.getOrDefault($typ))
  if holder.isNil:
    tt.table[$typ] = Holder[T](value: val)
  else:
    holder.value = val

type
  BuildDep* = object
    deps: seq[string]
    outs: seq[string]
    run: proc(b: Builder)

  Builder* = ref object
    context: TypeTable
    deps: seq[BuildDep]

proc with*[T](builder: Builder, val: T): T {.discardable.} =
  let buildDep = T.getBuildDeps(val)
  builder.deps.add(buildDep)

template with*(switchBuilder: Builder, args: varargs[untyped]) =
  when args is ref:
    switchBuilder.with(new(args))
  else:
    switchBuilder.with(default(args))

proc build*[T](builder: Builder, val: type[T]): T {.discardable.} =
  builder.with(T)
  while builder.deps.len > 0:
    for index, dep in builder.deps:
      var canBeRun = true
      for dep in dep.deps:
        if dep notin builder.context:
          canBeRun = false
      if canBeRun == false: continue

      dep.run(builder)
      builder.deps.delete(index)
      break

  builder.context[T]

macro setupproc(prc: untyped): untyped =
  result = nnkStmtList.newTree(prc)

  let
    buildDepsProc = newProc(ident"getBuildDeps")
    targetType =
      if params(prc)[1][1].kind == nnkVarTy: params(prc)[1][1][0]
      else: params(prc)[1][1]
    targetTypeParam = nnkIdentDefs.newTree(
      ident"T",
      nnkBracketExpr.newTree(ident"type", targetType),
      newEmptyNode()
    )
    targetValParam = nnkIdentDefs.newTree(
      ident"val",
      targetType,
      newEmptyNode()
    )

    setResult = quote do: result = BuildDep()

  buildDepsProc.params = nnkFormalParams.newTree(
    ident"BuildDep",
    targetTypeParam,
    targetValParam
  )

  buildDepsProc.body = nnkStmtList.newTree(
    setResult
  )

  for setupParam in params(prc)[2..^1]:
    if setupParam[1].kind == nnkVarTy:
      let paramType = newStrLitNode($setupParam[1][0])
      buildDepsProc.body.add(
        quote do: result.outs.add(`paramType`)
      )
    else:
      let paramType = newStrLitNode($setupParam[1])
      buildDepsProc.body.add(
        quote do: result.deps.add(`paramType`)
      )

  let
    builderParam = nnkIdentDefs.newTree(ident"b", ident"Builder", newEmptyNode())
    runnerProc = newProc(params = [newEmptyNode(), builderParam])
    beforeCall = nnkStmtList.newTree()
    valCopyIdent = ident"valCopy"
    caller = newCall("setup", valCopyIdent)
    afterCall = nnkStmtList.newTree()
  var paramCount = 0
  for setupParam in params(prc)[2..^1]:
    if setupParam[1].kind == nnkVarTy:
      let
        paramType = setupParam[1][0]
        paramTempName = ident("p" & $paramCount)
      paramCount.inc()
      beforeCall.add(quote do:
        var `paramTempName` = b.context[`paramType`]
      )
      caller.add(paramTempName)
      afterCall.add(quote do: b.context[`paramType`] = `paramTempName`)
    else:
      let paramType = setupParam[1]
      caller.add(
        quote do: b.context[`paramType`]
      )
  runnerProc.body = nnkStmtList.newTree(
    (quote do:
      var `valCopyIdent` = if val == default(`targetType`): b.context[`targetType`] else: val),
    beforeCall,
    caller,
    afterCall,
    quote do: b.context[`targetType`] = `valCopyIdent`
  )

  buildDepsProc.body.add(
    quote do: result.run = `runnerProc`
  )
  result.add(buildDepsProc)
  echo repr(result)

when isMainModule:
  proc setup(i: int, x: float, res: var string) {.setupproc.} =
    res = $(i.float + x)

  proc setup(i: var float) {.setupproc.} =
    i = 10.12

  proc setup(i: var string) {.setupproc.} =
    discard

  let builder = Builder()
  builder.with(5)
  builder.with(float)
  echo builder.build(string)
