import std/[macros]

var globalYeahStack* {.global, threadvar.}: seq[string]
var globalYeahInt {.global, threadvar.}: int

macro asyncyeah*(functionlike: untyped{nkProcDef | nkMethodDef | nkFuncDef}): untyped =
  let fl = functionlike.copyNimTree
  let closureName = newStrLitNode($fl[0])
  var body = fl[6].copyNimTree

  var newBody = newStmtList()
  newBody.add(quote do:
    inc globalYeahInt
    let callName = `closureName` & $globalYeahInt
    # echo "push " & callName
    globalYeahStack.add(callName)
    defer:
      let rmIndex = globalYeahStack.find(callName)
      globalYeahStack.del(rmIndex)
      # echo "pop " & callName
  )
  body.copyChildrenTo(newBody)

  fl.body = newBody

  let pragmas = fl[4]
  var newPragmas = newNimNode(nnkPragma)
  for pragma in pragmas:
    if not pragma.eqIdent("asyncyeah"):
      newPragmas.add(pragma)
  newPragmas.add(ident("async"))
  fl[4] = newPragmas
  return fl
