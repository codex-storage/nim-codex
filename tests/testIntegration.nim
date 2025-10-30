import std/os
import std/strutils
import ./imports

## Limit which integration tests to run by setting the
## environment variable during compilation. For example:
## CODEX_INTEGRATION_TEST_INCLUDES="testFoo.nim,testBar.nim"
const includes = getEnv("CODEX_INTEGRATION_TEST_INCLUDES")

when includes != "":
  # import only the specified tests
  importAll(includes.split(","))
else:
  # import all tests in the integration/ directory
  importTests(currentSourcePath().parentDir() / "integration")

{.warning[UnusedImport]: off.}
