import os
import std/strutils

import ../../asynctest

import pkg/chronos
import pkg/confutils/defs
import pkg/codex/conf
import pkg/codex/slots/proofs/backends
import pkg/codex/slots/proofs/backendfactory
import pkg/codex/slots/proofs/backendutils

import ../helpers

type
  BackendUtilsMock = ref object of BackendUtils
    argR1csFile: string
    argWasmFile: string
    argZKeyFile: string
    argUrl: string
    argFilepath: string
    argZipFile: string
    argOutputDir: string

method initializeCircomBackend*(
  self: BackendUtilsMock,
  r1csFile: string,
  wasmFile: string,
  zKeyFile: string
): AnyBackend =
  self.argR1csFile = r1csFile
  self.argWasmFile = wasmFile
  self.argZKeyFile = zKeyFile
  # We return a backend with *something* that's not nil that we can check for.
  var 
    key = VerifyingKey(icLen: 123)
    vkpPtr: ptr VerifyingKey = key.addr
  return CircomCompat(vkp: vkpPtr)

method downloadFile*(
  self: BackendUtilsMock,
  url: string,
  filepath: string
): ?!void =
  self.argUrl = url
  self.argFilepath = filepath
  success()

method unzipFile*(
  self: BackendUtilsMock,
  zipFile: string,
  outputDir: string): ?!void =
  self.argZipFile = zipFile
  self.argOutputDir = outputDir
  try:
    writeFile(outputDir / "proof_main.r1cs", "r1cs_file")
    writeFile(outputDir / "proof_main.wasm", "wasm_file")
    writeFile(outputDir / "proof_main.zkey", "zkey_file")
  except Exception as exc:
    return failure(exc.msg)
  success()

suite "Test BackendFactory":
  let
    utilsMock = BackendUtilsMock()
    datadir = "testdatadir"

  setup:
    createDir(datadir)

  teardown:
    removeDir(datadir)

  test "Should create backend from cli config":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: ValidIpAddress.init("127.0.0.1"),
        discoveryIp: ValidIpAddress.init(IPv4_any()),
        metricsAddress: ValidIpAddress.init("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
        circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
        circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey")
      )
      ceremonyHash = string.none
      backend = (await initializeBackend(config, ceremonyHash, utilsMock)).tryGet

    check:
      backend.vkp != nil
      utilsMock.argR1csFile == $config.circomR1cs
      utilsMock.argWasmFile == $config.circomWasm
      utilsMock.argZKeyFile == $config.circomZkey
      isEmptyOrWhitespace(utilsMock.argUrl)
      isEmptyOrWhitespace(utilsMock.argFilepath)
      isEmptyOrWhitespace(utilsMock.argZipFile)
      isEmptyOrWhitespace(utilsMock.argOutputDir)

  test "Should create backend from local files":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: ValidIpAddress.init("127.0.0.1"),
        discoveryIp: ValidIpAddress.init(IPv4_any()),
        metricsAddress: ValidIpAddress.init("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,

        # Set the datadir such that the tests/circuits/fixtures/ files
        # will be picked up as local files:
        dataDir: OutDir("tests/circuits/fixtures")
      )
      ceremonyHash = string.none
      backend = (await initializeBackend(config, ceremonyHash, utilsMock)).tryGet

    check:
      backend.vkp != nil
      utilsMock.argR1csFile == config.dataDir / "proof_main.r1cs"
      utilsMock.argWasmFile == config.dataDir / "proof_main.wasm"
      utilsMock.argZKeyFile == config.dataDir / "proof_main.zkey"
      isEmptyOrWhitespace(utilsMock.argUrl)
      isEmptyOrWhitespace(utilsMock.argFilepath)
      isEmptyOrWhitespace(utilsMock.argZipFile)
      isEmptyOrWhitespace(utilsMock.argOutputDir)

  test "Should download and unzip ceremony file if not available":
    let
      ceremonyHash = some "12345"
      expectedZip = datadir / "circuit.zip"
      expectedUrl = "https://circuit.codex.storage/proving-key/" & !ceremonyHash
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: ValidIpAddress.init("127.0.0.1"),
        discoveryIp: ValidIpAddress.init(IPv4_any()),
        metricsAddress: ValidIpAddress.init("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        dataDir: OutDir(datadir)
      )

      backend = (await initializeBackend(config, ceremonyHash, utilsMock)).tryGet

    check:
      backend.vkp != nil
      utilsMock.argR1csFile == config.dataDir / "proof_main.r1cs"
      utilsMock.argWasmFile == config.dataDir / "proof_main.wasm"
      utilsMock.argZKeyFile == config.dataDir / "proof_main.zkey"
      utilsMock.argUrl == expectedUrl
      utilsMock.argFilepath == expectedZip
      utilsMock.argZipFile == expectedZip
      utilsMock.argOutputDir == datadir
