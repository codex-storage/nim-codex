{.push raises: [].}

import os
import strutils
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/confutils/defs
import pkg/stew/io2
import pkg/ethers
import pkg/taskpools

import ../../conf
import ./backends
import ./prover

template graphFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.bin"

template r1csFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.r1cs"

template wasmFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.wasm"

template zkeyFilePath(config: CodexConf): string =
  config.circuitDir / "proof_main.zkey"

proc getGraphFile*(config: CodexConf): ?!string =
  if fileAccessible($config.circomGraph, {AccessFlags.Read}) and
      endsWith($config.circomGraph, ".bin"):
    success $config.circomGraph
  elif fileAccessible(config.graphFilePath, {AccessFlags.Read}) and
      endsWith(config.graphFilePath, ".bin"):
    success config.graphFilePath
  else:
    failure("Graph file not accessible or not found")

proc getR1csFile*(config: CodexConf): ?!string =
  if fileAccessible($config.circomR1cs, {AccessFlags.Read}) and
      endsWith($config.circomR1cs, ".r1cs"):
    success $config.circomR1cs
  elif fileAccessible(config.r1csFilePath, {AccessFlags.Read}) and
      endsWith(config.r1csFilePath, ".r1cs"):
    success config.r1csFilePath
  else:
    failure("R1CS file not accessible or not found")

proc getWasmFile*(config: CodexConf): ?!string =
  if fileAccessible($config.circomWasm, {AccessFlags.Read}) and
      endsWith($config.circomWasm, ".wasm"):
    success $config.circomWasm
  elif fileAccessible(config.wasmFilePath, {AccessFlags.Read}) and
      endsWith(config.wasmFilePath, ".wasm"):
    success config.wasmFilePath
  else:
    failure("WASM file not accessible or not found")

proc getZkeyFile*(config: CodexConf): ?!string =
  if fileAccessible($config.circomZkey, {AccessFlags.Read}) and
      endsWith($config.circomZkey, ".zkey"):
    success $config.circomZkey
  elif fileAccessible(config.zkeyFilePath, {AccessFlags.Read}) and
      endsWith(config.zkeyFilePath, ".zkey"):
    success config.zkeyFilePath
  else:
    failure("ZKey file not accessible or not found")

proc suggestDownloadTool(config: CodexConf) =
  without address =? config.marketplaceAddress:
    raise (ref Defect)(
      msg: "Proving backend initializing while marketplace address not set."
    )

  let
    tokens = ["cirdl", "\"" & $config.circuitDir & "\"", config.ethProvider, $address]
    instructions = "'./" & tokens.join(" ") & "'"

  warn "Proving circuit files are not found. Please run the following to download them:",
    instructions

proc initializeNimGroth16Backend(
    config: CodexConf, tp: Taskpool
): ?!NimGroth16BackendRef =
  let
    graphFile = ?getGraphFile(config)
    r1csFile = ?getR1csFile(config)
    zkeyFile = ?getZkeyFile(config)

  return NimGroth16BackendRef.new(
    $graphFile,
    $r1csFile,
    $zkeyFile,
    config.nimGroth16Curve,
    config.maxSlotDepth,
    config.maxDatasetDepth,
    config.maxBlockDepth,
    config.maxCellElms,
    config.numProofSamples,
    tp,
  )

proc initializeCircomCompatBackend(
    config: CodexConf, tp: Taskpool
): ?!CircomCompatBackendRef =
  let
    r1csFile = ?getR1csFile(config)
    wasmFile = ?getWasmFile(config)
    zkeyFile = ?getZkeyFile(config)

  return CircomCompatBackendRef.new(
    $r1csFile,
    $wasmFile,
    $zkeyFile,
    config.maxSlotDepth,
    config.maxDatasetDepth,
    config.maxBlockDepth,
    config.maxCellElms,
    config.numProofSamples,
  )

proc initializeProver*(config: CodexConf, tp: Taskpool): ?!Prover =
  let prover =
    case config.proverBackendCmd
    of ProverBackendCmd.nimGroth16:
      without backend =? initializeNimGroth16Backend(config, tp), err:
        suggestDownloadTool(config)
        return failure("Unable to initialize NimGroth16 backend")

      Prover.new(backend, config.numProofSamples, tp)
    of ProverBackendCmd.circomCompat:
      without backend =? initializeCircomCompatBackend(config, tp), err:
        suggestDownloadTool(config)
        return failure("Unable to initialize CircomCompat backend")

      Prover.new(backend, config.numProofSamples, tp)

  success prover
