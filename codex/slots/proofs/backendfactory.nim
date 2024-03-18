import os
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/confutils/defs
import pkg/stew/io2

import ../../conf
import ./backends
import ./backendutils

proc initializeFromConfig(
  config: CodexConf,
  utils: BackendUtils): ?!AnyBackend =
  if not fileAccessible($config.circomR1cs, {AccessFlags.Read}) or
    not endsWith($config.circomR1cs, ".r1cs"):
    return failure("Circom R1CS file not accessible")

  if not fileAccessible($config.circomWasm, {AccessFlags.Read}) or
    not endsWith($config.circomWasm, ".wasm"):
    return failure("Circom wasm file not accessible")

  if not fileAccessible($config.circomZkey, {AccessFlags.Read}) or
    not endsWith($config.circomZkey, ".zkey"):
    return failure("Circom zkey file not accessible")

  trace "Initialized prover backend from cli config"
  success(utils.initializeCircomBackend(
    $config.circomR1cs,
    $config.circomWasm,
    $config.circomZkey))

proc r1csFilePath(config: CodexConf): string =
  config.dataDir / "proof_main.r1cs"

proc wasmFilePath(config: CodexConf): string =
  config.dataDir / "proof_main.wasm"

proc zkeyFilePath(config: CodexConf): string =
  config.dataDir / "proof_main.zkey"

proc zipFilePath(config: CodexConf): string =
  config.dataDir / "circuit.zip"

proc initializeFromCeremonyFiles(
  config: CodexConf,
  utils: BackendUtils): ?!AnyBackend =
  if fileExists(config.r1csFilePath) and
    fileExists(config.wasmFilePath) and
    fileExists(config.zkeyFilePath):
    trace "Initialized prover backend from local files"
    return success(utils.initializeCircomBackend(
      config.r1csFilePath,
      config.wasmFilePath,
      config.zkeyFilePath))

  failure("Ceremony files not found")

proc downloadCeremony(
  config: CodexConf,
  ceremonyHash: string,
  utils: BackendUtils
): ?!void =
  # TODO:
  # In the future, the zip file will be stored in the Codex network
  # instead of a url + ceremonyHash, we'll get a CID from the marketplace contract.

  let url = "https://circuit.codex.storage/proving-key/" & ceremonyHash
  trace "Downloading ceremony file", url, filepath = config.zipFilePath
  return utils.downloadFile(url, config.zipFilePath)

proc unzipCeremonyFile(
  config: CodexConf,
  utils: BackendUtils): ?!void =
  trace "Unzipping..."
  return utils.unzipFile(config.zipFilePath, $config.dataDir)

proc initializeFromCeremonyHash(
  config: CodexConf,
  ceremonyHash: ?string,
  utils: BackendUtils): Future[?!AnyBackend] {.async.} =

  if hash =? ceremonyHash:
    if dlErr =? downloadCeremony(config, hash, utils).errorOption:
      return failure(dlErr)
    if err =? unzipCeremonyFile(config, utils).errorOption:
      return failure(err)
    without backend =? initializeFromCeremonyFiles(config, utils), err:
      return failure(err)
    return success(backend)
  else:
    return failure("Ceremony URL not found")

proc initializeBackend*(
  config: CodexConf,
  ceremonyHash: ?string,
  utils: BackendUtils = BackendUtils()): Future[?!AnyBackend] {.async.} =

  without backend =? initializeFromConfig(config, utils), cliErr:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    without backend =? initializeFromCeremonyFiles(config, utils), localErr:
      info "Could not initialize prover backend from local files...", msg = localErr.msg
      without backend =? (await initializeFromCeremonyHash(config, ceremonyHash, utils)), urlErr:
        warn "Could not initialize prover backend from ceremony url...", msg = urlErr.msg
        return failure(urlErr)
  return success(backend)
