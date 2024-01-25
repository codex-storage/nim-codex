import macros
import strutils
import pkg/questionable
import pkg/questionable/operators

export questionable

proc `as`*[T](value: T, U: type): ?U =
  ## Casts a value to another type, returns an Option.
  ## When the cast succeeds, the option will contain the casted value.
  ## When the cast fails, the option will have no value.
  when value is U:
    return some value
  elif value is ref object:
    if value of U:
      return some U(value)

Option.liftBinary `as`

template WrapOption*(input: untyped): type =
  when input is Option:
    input
  else:
    Option[input]


template Optionalize*(t: typed): untyped =
  ## Takes object type and wraps all the first level fields into
  ## Option type unless it is already Option type.
  createType(t)

macro createType*(t: typedesc): untyped =
  var objectType = getType(t)

  # Work around for https://github.com/nim-lang/Nim/issues/23112
  while objectType.kind == nnkBracketExpr and objectType[0].eqIdent"typeDesc":
    objectType = getType(objectType[1])

  expectKind(objectType, NimNodeKind.nnkObjectTy)
  var fields = nnkRecList.newTree()

  for field in objectType[2]:
    let fieldType = getTypeInst(field)
    let newFieldNode =
          nnkIdentDefs.newTree(newIdentNode($field), nnkCall.newTree(ident("WrapOption"), fieldType), newEmptyNode())

    fields.add(newFieldNode)


  nnkStmtList.newTree(
      nnkTypeSection.newTree(
        nnkTypeDef.newTree(ident("T"), newEmptyNode(), nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields))
      ),
      ident("T")
  )
