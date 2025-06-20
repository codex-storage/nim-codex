import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "tools")

{.warning[UnusedImport]: off.}
