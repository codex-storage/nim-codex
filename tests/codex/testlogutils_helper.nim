import pkg/codex/logutils

type
  ObjectType2* = object
    a*: string

# must be defined at the top-level
logutils.formatIt(ObjectType2): "o2_formatted_" & it.a