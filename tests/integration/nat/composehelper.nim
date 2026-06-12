## Helpers shared by the compose-driven NAT scenario tests (real topology, not
## the in-process simulation). Each scenario provides its own compose.yml and
## the list of services whose logs should be collected.

import std/[os, osproc]
import ../utils

proc compose*(composeFile, action: string) =
  let cmd = "podman-compose -f \"" & composeFile & "\" " & action
  doAssert execShellCmd(cmd) == 0, "command failed: " & cmd

proc saveContainerLogs*(
    composeFile, suiteName, testName, startTime: string, services: openArray[string]
) =
  ## Writes each container's log via getLogFile, the same helper and layout as
  ## the multinodes suite: tests/integration/logs/<startTime>__<suiteName>/
  ## <testName>/<service>.log. Must run before `down` destroys the containers.
  for service in services:
    try:
      let
        logFile = getLogFile("", startTime, suiteName, testName, service)
        cmd = "podman-compose -f \"" & composeFile & "\" logs " & service
        (output, code) = execCmdEx(cmd)
      if code != 0:
        echo "warning: '", cmd, "' exited ", code
      writeFile(logFile, output)
    except CatchableError as e:
      echo "could not save logs for ", service, ": ", e.msg
