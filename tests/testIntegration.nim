import std/os
import std/strutils
import ./imports

## Limit which integration tests to run by setting the
## environment variable during compilation. For example:
## STORAGE_INTEGRATION_TEST_INCLUDES="testFoo.nim,testBar.nim"
const includes = getEnv("STORAGE_INTEGRATION_TEST_INCLUDES")

when includes != "":
  # import only the specified tests
  importAll(includes.split(","))
else:
  # all tests in integration/, except the nat/ real-topology scenarios, which
  # need podman + the storage-nat image and run via testNatIntegration instead
  importTests(currentSourcePath().parentDir() / "integration", "/nat/")

{.warning[UnusedImport]: off.}
