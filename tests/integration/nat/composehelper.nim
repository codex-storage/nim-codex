## Helpers shared by the compose-driven NAT scenario tests (real topology, not
## the in-process simulation). Each scenario provides its own compose.yml and
## the list of services whose logs should be collected.

import std/[os, osproc]
import ../utils

const
  routerWanIp* = "7.7.7.2" ## public IP AutoNAT observes for a NATed node (masquerade)
  bootstrapIp* = "7.7.7.10" ## relay + bootstrap public IP

proc composeCmd(composeFile: string): string =
  ## Prefer podman (where the Makefile builds the image), fall back to docker.
  let base =
    if findExe("podman-compose") != "":
      "podman-compose"
    elif findExe("podman") != "":
      "podman compose"
    elif findExe("docker") != "":
      "docker compose"
    else:
      raise newException(IOError, "neither podman nor docker found")
  base & " -f \"" & composeFile & "\""

proc compose*(composeFile, action: string) =
  let cmd = composeCmd(composeFile) & " " & action
  doAssert execShellCmd(cmd) == 0, "command failed: " & cmd

proc serviceLogs*(composeFile, service: string): string =
  ## Current logs (stdout+stderr) of a compose service, or "" on error.
  try:
    let
      cmd = composeCmd(composeFile) & " logs " & service
      (output, code) = execCmdEx(cmd)
    if code != 0:
      echo "warning: '", cmd, "' exited ", code
    output
  except CatchableError as e:
    echo "could not read logs for ", service, ": ", e.msg
    ""

proc saveContainerLogs*(
    composeFile, suiteName, testName, startTime: string, services: openArray[string]
) =
  ## Writes each container's log via getLogFile, the same helper and layout as
  ## the multinodes suite: tests/integration/logs/<startTime>__<suiteName>/
  ## <testName>/<service>.log. Must run before `down` destroys the containers.
  for service in services:
    try:
      let logFile = getLogFile("", startTime, suiteName, testName, service)
      writeFile(logFile, serviceLogs(composeFile, service))
    except CatchableError as e:
      echo "could not save logs for ", service, ": ", e.msg

template eventuallyInfo*(client, predicate: untyped): bool =
  ## Poll `client.info()` until `predicate` holds, swallowing HttpError while the
  ## node's API is still starting. The decoded info JsonNode is exposed as `info`
  ## inside `predicate`.
  eventuallySafe(
    block:
      var satisfied = false
      try:
        let res = await client.info()
        if res.isOk:
          let info {.inject.} = res.get
          satisfied = predicate
      except HttpError:
        discard
      satisfied,
    timeout = 300000,
    pollInterval = 5000,
  )
