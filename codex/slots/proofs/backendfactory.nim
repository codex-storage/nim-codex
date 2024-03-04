import os
import httpclient
import zip/zipfiles
import pkg/chronos
import pkg/chronicles
import pkg/questionable
import pkg/confutils/defs
import pkg/stew/io2

import ../../conf
import ./backends

proc initializeCircomBackend(
  r1csFile: string,
  wasmFile: string,
  zKeyFile: string
): AnyBackend =
  CircomCompat.init(r1csFile, wasmFile, zKeyFile)

proc initializeFromConfig(
  config: CodexConf): ?!AnyBackend =
  if not fileAccessible($config.circomR1cs, {AccessFlags.Read}) and
    endsWith($config.circomR1cs, ".r1cs"):
    return failure("Circom R1CS file not accessible")

  if not fileAccessible($config.circomWasm, {AccessFlags.Read}) and
    endsWith($config.circomWasm, ".wasm"):
    return failure("Circom wasm file not accessible")

  if not fileAccessible($config.circomZkey, {AccessFlags.Read}) and
    endsWith($config.circomZkey, ".zkey"):
    return failure("Circom zkey file not accessible")

  trace "Initialized prover backend from cli config"
  success(initializeCircomBackend(
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

proc initializeFromCeremonyFiles(config: CodexConf): ?!AnyBackend =
  if fileExists(config.r1csFilePath) and
    fileExists(config.wasmFilePath) and
    fileExists(config.zkeyFilePath):
    trace "Initialized prover backend from local files"
    return success(initializeCircomBackend(
      config.r1csFilePath,
      config.wasmFilePath,
      config.zkeyFilePath))

  failure("Ceremony files not found")

proc downloadCeremony(
  config: CodexConf,
  ceremonyHash: string
): ?!void =
  # TODO:
  # In the future, the zip file will be stored in the Codex network
  # instead of a url + ceremonyHash, we'll get a CID from the marketplace contract.

  echo "OVERRIDE!"
  let hash = "1f512a1c6a089eff7eb22b810438c34fc59d4b0e7935dbc77ec77255d39ec094"

  let url = "https://circuit.codex.storage/proving-key/" & hash # was ceremonyHash
  trace "Downloading ceremony file", url, filepath = config.zipFilePath
  try:
    # Nim's default webclient does not support SSL on all platforms.
    # Not without shipping additional binaries and cert-files... :(
    # So we're using curl for now.
    var rc = execShellCmd("curl -o " & config.zipFilePath & " " & url)
    if not rc == 0:
      return failure("Download failed with return code: " & $rc)
  except Exception as exc:
    return failure(exc.msg)
  trace "Download completed."
  success()

proc unzipCeremonyFile(
  config: CodexConf): ?!void =
  trace "Unzipping..."
  var z: ZipArchive
  if not z.open(config.zipFilePath):
    return failure("Unable to open zip file: " & config.zipFilePath)
  z.extractAll($config.dataDir)
  success()

proc initializeFromCeremonyHash(
  config: CodexConf,
  ceremonyHash: ?string): Future[?!AnyBackend] {.async.} =

  if hash =? ceremonyHash:
    if dlErr =? downloadCeremony(config, hash).errorOption:
      return failure(dlErr)
    if err =? unzipCeremonyFile(config).errorOption:
      return failure(err)
    without backend =? initializeFromCeremonyFiles(config), err:
      return failure(err)
    return success(backend)
  else:
    return failure("Ceremony URL not found")

proc initializeBackend*(
  config: CodexConf,
  ceremonyHash: ?string): Future[?!AnyBackend] {.async.} =

  without backend =? initializeFromConfig(config), cliErr:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    without backend =? initializeFromCeremonyFiles(config), localErr:
      info "Could not initialize prover backend from local files...", msg = localErr.msg
      without backend =? (await initializeFromCeremonyHash(config, ceremonyHash)), urlErr:
        warn "Could not initialize prover backend from ceremony url...", msg = urlErr.msg
        return failure(urlErr)
  return success(backend)
