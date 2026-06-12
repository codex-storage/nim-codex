import std/os
import ./imports

## Real-topology NAT scenarios (need podman + the storage-nat image).
## Run a single scenario by setting its folder name during compilation, e.g.
## STORAGE_INTEGRATION_TEST_INCLUDES=reachable
const scenario = getEnv("STORAGE_INTEGRATION_TEST_INCLUDES")
const only =
  if scenario.len > 0:
    "/" & scenario & "/"
  else:
    ""

importTests(currentSourcePath().parentDir() / "integration" / "nat", "", only)

{.warning[UnusedImport]: off.}
