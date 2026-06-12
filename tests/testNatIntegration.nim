import std/os
import std/strutils
import ./imports

## Real-topology NAT scenarios (need podman + the storage-nat image).
## Limit which scenarios run with STORAGE_INTEGRATION_TEST_INCLUDES, listing test
## file paths, exactly as testIntegration does.
const includes = getEnv("STORAGE_INTEGRATION_TEST_INCLUDES")

when includes != "":
  importAll(includes.split(","))
else:
  importTests(currentSourcePath().parentDir() / "integration" / "nat", "")

{.warning[UnusedImport]: off.}
