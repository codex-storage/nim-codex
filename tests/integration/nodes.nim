import std/osproc
import std/os
import std/streams
import std/strutils

const workingDir = currentSourcePath() / ".." / ".." / ".."
const executable = "build" / "codex"

proc startNode*(args: openArray[string], debug = false): Process =
  if debug:
    result = startProcess(executable, workingDir, args, options={poParentStreams})
    sleep(1000)
  else:
    result = startProcess(executable, workingDir, args)
    for line in result.outputStream.lines:
      if line.contains("Started codex node"):
        break

proc stop*(node: Process) =
  node.terminate()
  discard node.waitForExit(timeout=5_000)
  node.close()
