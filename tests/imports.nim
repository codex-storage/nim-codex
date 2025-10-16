import std/macros
import std/os
import std/strutils

macro importTests*(dir: static string, excludes: static string = ""): untyped =
  ## imports all files in the specified directory whose filename
  ## starts with "test" and ends in ".nim"
  let imports = newStmtList()
  let excludeList = excludes.split(",")
  for file in walkDirRec(dir):
    let (_, name, ext) = splitFile(file)
    if name.startsWith("test") and ext == ".nim" and not (name in excludeList):
      imports.add(
        quote do:
          import `file`
      )
  imports

macro importAll*(paths: static seq[string]): untyped =
  ## imports all specified paths
  let imports = newStmtList()
  for path in paths:
    imports.add(
      quote do:
        import `path`
    )
  imports
