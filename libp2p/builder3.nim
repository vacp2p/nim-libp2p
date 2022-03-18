# Nim-Libp2p
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [Defect].}

import std/[tables, macros, sequtils, strutils]

type
  GenHolder = ref object of RootObj

  Holder[T] = ref object of GenHolder
    prettyName: string
    value: T

  TypeTable = object
    table: Table[string, GenHolder]

proc getTypeNameRecur(n: NimNode): string {.compiletime.} =
  # can't do something safer because of
  # https://github.com/nim-lang/Nim/issues/19617
  #
  # two different types with the same name in different modules
  # might clash
  case n.kind:
  of nnkSym:
    $n
  of nnkBracketExpr:
    getTypeNameRecur(n[0]) & "[" & getTypeNameRecur(n[1]) & "]"
  else:
    assert false
    "unsupported"

macro getTypeName*(s: typed): untyped =
  let
    typInst = getType(s)
    stripped =
      if typInst.kind == nnkBracketExpr and typInst[0].eqIdent("typedesc"):
        typInst[1]
      else:
        typInst

  newLit(getTypeNameRecur(stripped))

proc contains[T](tt: TypeTable, typ: type[T]): bool =
  tt.table.contains(getTypeName(T))

proc contains(tt: TypeTable, typ: string): bool =
  tt.table.contains(typ)

proc `[]`[T](tt: TypeTable, typ: type[T]): T =
  let holder = Holder[T](tt.table.getOrDefault(getTypeName(T)))
  if holder.isNil:
    default(T)
  else:
    holder.value

proc `[]=`[T](tt: var TypeTable, typ: type[T], val: T) =
  let holder = Holder[T](tt.table.getOrDefault(getTypeName(T)))
  if holder.isNil:
    tt.table[getTypeName(T)] = Holder[T](value: val)
  else:
    holder.value = val

type
  BuildDep* = object
    deps: seq[string]
    outs: seq[string]
    run: proc(b: Builder) {.raises: [Exception].}

  Builder* = ref object
    context: TypeTable
    deps: seq[BuildDep]

proc with*[T](builder: Builder, val: T): T {.discardable.} =
  let buildDep = T.getBuildDeps(val)
  builder.deps.add(buildDep)

template with*(switchBuilder: Builder, args: varargs[untyped]) =
  #TODO find a better test
  when not compiles(args isnot string):
    switchBuilder.with(new(args))
  elif args is ref:
    switchBuilder.with(new(args))
  else:
    switchBuilder.with(default(args))

{.pop.} # building can raise anything the setup can
proc build*[T](builder: Builder, val: type[T]): T {.discardable.} =
  builder.with(T)

  # Kick & dirty dependency solver
  while builder.deps.len > 0:
    echo builder.deps, ": ", toSeq(builder.context.table.keys())

    for index, buildAttempt in builder.deps:
      var canBeRun = true
      for dep in buildAttempt.deps:
        # Do we have every dep?
        if dep notin builder.context:
          echo "Missing for ", buildAttempt.outs[0], ": ", dep
          canBeRun = false

        # Someone still have to output a dep?
        for index2, otherDep in builder.deps:
          if index != index2 and dep in otherDep.outs:
            echo "Missing for ", buildAttempt.outs[0], ": ", dep
            canBeRun = false
      if canBeRun == false: continue

      buildAttempt.run(builder)
      builder.deps.delete(index)
      break

  builder.context[T]

macro setupproc*(prc: untyped): untyped =
  result = nnkStmtList.newTree(prc)

  let
    buildDepsProc = newProc(nnkPostFix.newTree(ident"*", ident"getBuildDeps"))
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

  buildDepsProc.body.add(
    quote do: result.outs.add(getTypeName(`targetType`))
  )
  for setupParam in params(prc)[2..^1]:
    if setupParam[1].kind == nnkVarTy:
      let paramType = setupParam[1][0]
      buildDepsProc.body.add(
        quote do: result.outs.add(getTypeName(`paramType`))
      )
    else:
      let paramType = setupParam[1]
      buildDepsProc.body.add(
        quote do: result.deps.add(getTypeName(`paramType`))
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

  doAssert getTypeName(int) == "int"
  doAssert getTypeName(seq[iNT]) == "seq[int]"

  type
    hello = int
    hello3 = distinct int
  doAssert getTypeName(hello) == "int"
  doAssert getTypeName(hello3) == "hello3"
  doAssert getTypeName(ref int) == "ref[int]"
