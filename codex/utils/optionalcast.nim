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
