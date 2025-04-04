import pkg/questionable
import pkg/questionable/results
import pkg/confutils
import pkg/chronicles
import pkg/chronos/asyncproc
import pkg/ethers
import pkg/libp2p
import std/os
import std/strutils
import codex/conf
import ./codexclient
import ./nodeprocess

export codexclient
export chronicles
export nodeprocess

logScope:
  topics = "integration testing codex process"

type CodexProcess* = ref object of NodeProcess
  client: ?CodexClient

method workingDir(node: CodexProcess): string =
  return currentSourcePath() / ".." / ".." / ".."

method executable(node: CodexProcess): string =
  return "build" / "codex"

method startedOutput(node: CodexProcess): string =
  return "REST service started"

method processOptions(node: CodexProcess): set[AsyncProcessOption] =
  return {AsyncProcessOption.StdErrToStdOut}

method outputLineEndings(node: CodexProcess): string {.raises: [].} =
  return "\n"

method onOutputLineCaptured(node: CodexProcess, line: string) {.raises: [].} =
  discard

proc dataDir(node: CodexProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments, quitOnFailure = false)
  return config.dataDir.string

proc ethAccount*(node: CodexProcess): Address =
  let config = CodexConf.load(cmdLine = node.arguments, quitOnFailure = false)
  without ethAccount =? config.ethAccount:
    raiseAssert "eth account not set"
  return Address(ethAccount)

proc apiUrl*(node: CodexProcess): string =
  let config = CodexConf.load(cmdLine = node.arguments, quitOnFailure = false)
  return "http://" & config.apiBindAddress & ":" & $config.apiPort & "/api/codex/v1"

proc client*(node: CodexProcess): CodexClient =
  if client =? node.client:
    return client
  let client = CodexClient.new(node.apiUrl)
  node.client = some client
  return client

method stop*(node: CodexProcess) {.async.} =
  logScope:
    nodeName = node.name

  await procCall NodeProcess(node).stop()

  trace "stopping codex client"
  if client =? node.client:
    await client.close()
    node.client = none CodexClient

method removeDataDir*(node: CodexProcess) =
  removeDir(node.dataDir)
