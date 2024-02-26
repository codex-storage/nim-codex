import pkg/questionable

type
  CliOption* = object of RootObj
    nodeIdx*: ?int
    key*: string
    value*: string

proc `$`*(option: CliOption): string =
  var res = option.key
  if option.value.len > 0:
    res &= "=" & option.value
  return res
