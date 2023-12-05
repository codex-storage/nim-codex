import std/options
import std/sequtils
import pkg/codex/units
import ./clioption
import ./nodeconfig

export nodeconfig
export clioption

type
  CodexConfig* = ref object of NodeConfig
    numNodes*: int
    cliOptions*: seq[CliOption]
    logTopics*: seq[string]

proc nodes*(config: CodexConfig, numNodes: int): CodexConfig =
  if numNodes < 0:
    raise newException(ValueError, "numNodes must be >= 0")

  var startConfig = config
  startConfig.numNodes = numNodes
  return startConfig

proc simulateProofFailuresFor*(
  config: CodexConfig,
  providerIdx: int,
  failEveryNProofs: int
): CodexConfig =

  if providerIdx > config.numNodes - 1:
    raise newException(ValueError, "provider index out of bounds")

  var startConfig = config
  startConfig.cliOptions.add(
    CliOption(
      nodeIdx: some providerIdx,
      key: "--simulate-proof-failures",
      value: $failEveryNProofs
    )
  )
  return startConfig

proc withLogTopics*(
  config: CodexConfig,
  topics: varargs[string]
): CodexConfig =

  var startConfig = config
  startConfig.logTopics = startConfig.logTopics.concat(@topics)
  return startConfig

proc withStorageQuota*(
  config: CodexConfig,
  quota: NBytes
): CodexConfig =

  var startConfig = config
  startConfig.cliOptions.add(
    CliOption(key: "--storage-quota", value: $quota)
  )
  return startConfig
