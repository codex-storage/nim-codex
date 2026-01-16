import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "contracts")

{.warning[UnusedImport]: off.}
