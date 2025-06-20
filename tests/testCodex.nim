import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "codex")

{.warning[UnusedImport]: off.}
