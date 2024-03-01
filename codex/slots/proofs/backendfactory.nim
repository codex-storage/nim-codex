import os
import httpclient
import zip/zipfiles
import pkg/chronos
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

  success(initializeCircomBackend(
    $config.circomR1cs,
    $config.circomWasm,
    $config.circomZkey))

proc r1csFilePath(config: CodexConf): string =
  config.dataDir / "circuit.r1cs"

proc wasmFilePath(config: CodexConf): string =
  config.dataDir / "circuit.wasm"

proc zkeyFilePath(config: CodexConf): string =
  config.dataDir / "circuit.zkey"

proc zipFilePath(config: CodexConf): string =
  config.dataDir / "circuit.zip"

proc initializeFromCeremonyFiles(config: CodexConf): ?!AnyBackend =
  if fileExists(config.r1csFilePath) and
    fileExists(config.wasmFilePath) and
    fileExists(config.zkeyFilePath):
    return success(initializeCircomBackend(
      config.r1csFilePath,
      config.wasmFilePath,
      config.zkeyFilePath))

  failure("Ceremony files not found")

proc downloadCeremonyUrl(
  config: CodexConf,
  proofCeremonyUrl: string
) =
  var client = newHttpClient()
  client.downloadFile(
    "https://circuit.codex.storage/proving-key/" & proofCeremonyUrl, config.zipFilePath)

proc unzipCeremonyFile(
  config: CodexConf): ?!void =
  var z: ZipArchive
  if not z.open(config.zipFilePath):
    return failure("Unable to open zip file: " & config.zipFilePath)
  z.extractAll($config.dataDir)
  success()

proc initializeFromCeremonyUrl(
  config: CodexConf,
  proofCeremonyUrl: ?string): Future[?!AnyBackend] {.async.} =

  if url =? proofCeremonyUrl:
    downloadCeremonyUrl(config, url)
    if err =? unzipCeremonyFile(config).errorOption:
      return failure(err)
    without backend =? initializeFromCeremonyFiles(config), err:
      return failure(err)
    return success(backend)
  else:
    return failure("Ceremony URL not found")

proc initializeBackend*(
  config: CodexConf,
  proofCeremonyUrl: ?string): Future[?!AnyBackend] {.async.} =

  without backend =? initializeFromConfig(config), cliErr:
    info "Could not initialize prover backend from CLI options...", msg = cliErr.msg
    without backend =? initializeFromCeremonyFiles(config), localErr:
      info "Could not initialize prover backend from local files...", msg = localErr.msg
      without backend =? (await initializeFromCeremonyUrl(config, proofCeremonyUrl)), urlErr:
        warn "Could not initialize prover backend from ceremony url...", msg = urlErr.msg
        return failure(urlErr)
  return success(backend)
