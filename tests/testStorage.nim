import std/os
import ./imports

importTests(currentSourcePath().parentDir() / "storage", "")

{.warning[UnusedImport]: off.}
