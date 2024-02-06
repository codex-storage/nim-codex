import std/strformat

proc msgDetail*(e: ref CatchableError): string =
  var msg = e.msg
  if e.parent != nil:
    msg = fmt"{msg} Inner exception: {e.parent.msg}"
  return msg

template launderBare*(body: untyped): untyped =
  ## Launders bare Exceptions into CatchableError. This is typically used to
  ## "fix" code that throws bare exceptions and won't compile with Chronos V4,
  ## and which cannot be fixed otherise, e.g. in system APIs like json.parseJson
  ## in Nim 1.6.x. It should only be used as a last resort.
  try:
    body
  except Defect as ex:
    raise ex
  except CatchableError as ex:
    raise ex
  except Exception as ex:
    raise newException(Defect, ex.msg, ex)
