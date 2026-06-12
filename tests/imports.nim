import std/macros
import std/os
import std/strutils

macro importTests*(
    dir: static string, exclude: static string, only: static string
): untyped =
  ## imports every test*.nim file under `dir` (recursively).
  ## `exclude` (when non-empty) skips files whose path contains it.
  ## `only` (when non-empty) keeps only files whose path contains it.
  let imports = newStmtList()
  for file in walkDirRec(dir):
    let (_, name, ext) = splitFile(file)
    if not (name.startsWith("test") and ext == ".nim"):
      continue
    if exclude.len > 0 and exclude in file:
      continue
    if only.len > 0 and only notin file:
      continue
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
