import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "integration")

{.warning[UnusedImport]: off.}
