import std/osproc
import std/os
import std/streams
import std/strutils

const workingDir = currentSourcePath() / ".." / ".." / ".."
const executable = "build" / "codex"

type NodeProcess* = ref object
  process: Process
  arguments: seq[string]
  debug: bool

proc start(node: NodeProcess) =
  if node.debug:
    node.process = startProcess(
      executable,
      workingDir,
      node.arguments,
      options={poParentStreams}
    )
    sleep(1000)
  else:
    node.process = startProcess(
      executable,
      workingDir,
      node.arguments
    )
    for line in node.process.outputStream.lines:
      if line.contains("Started codex node"):
        break

proc startNode*(args: openArray[string], debug = false): NodeProcess =
  ## Starts a Codex Node with the specified arguments.
  ## Set debug to 'true' to see output of the node.
  let node = NodeProcess(arguments: @args, debug: debug)
  node.start()
  node

proc stop*(node: NodeProcess) =
  if node.process != nil:
    node.process.terminate()
    discard node.process.waitForExit(timeout=5_000)
    node.process.close()
    node.process = nil

proc restart*(node: NodeProcess) =
  node.stop()
  node.start()
