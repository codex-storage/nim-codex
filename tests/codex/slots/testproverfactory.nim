import os
import ../../asynctest

import pkg/chronos
import pkg/taskpools

import pkg/confutils/defs
import pkg/codex/conf
import pkg/codex/slots/proofs/backends
import pkg/codex/slots/proofs/proverfactory {.all.}
import pkg/codex/utils/natutils

import ../helpers
import ../examples

suite "Test BackendFactory":
  let circuitDir = "testecircuitdir"

  setup:
    createDir(circuitDir)

  teardown:
    removeDir(circuitDir)

  test "Should initialize with correct nimGroth16 config files":
    let config = CodexConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackendCmd: ProverBackendCmd.nimGroth16,
      circomGraph: InputFile("tests/circuits/fixtures/proof_main.bin"),
      circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
      circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
    )

    check:
      getGraphFile(config).tryGet == $config.circomGraph
      getR1csFile(config).tryGet == $config.circomR1cs
      getZkeyFile(config).tryGet == $config.circomZkey

  test "Should initialize with correct circom compat config files":
    let config = CodexConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackendCmd: ProverBackendCmd.circomCompat,
      circomWasm: InputFile("tests/circuits/fixtures/proof_main.wasm"),
      circomR1cs: InputFile("tests/circuits/fixtures/proof_main.r1cs"),
      circomZkey: InputFile("tests/circuits/fixtures/proof_main.zkey"),
    )

    check:
      getWasmFile(config).tryGet == $config.circomWasm
      getR1csFile(config).tryGet == $config.circomR1cs
      getZkeyFile(config).tryGet == $config.circomZkey

  test "Should initialize circom compat from local directory":
    let config = CodexConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackendCmd: ProverBackendCmd.circomCompat,
      # Set the circuitDir such that the tests/circuits/fixtures/ files
      # will be picked up as local files:
      circuitDir: OutDir("tests/circuits/fixtures"),
    )

    check:
      getR1csFile(config).tryGet == config.circuitDir / "proof_main.r1cs"
      getWasmFile(config).tryGet == config.circuitDir / "proof_main.wasm"
      getZKeyFile(config).tryGet == config.circuitDir / "proof_main.zkey"

  test "Should initialize nim groth16 from local directory":
    let config = CodexConf(
      cmd: StartUpCmd.persistence,
      nat: NatConfig(hasExtIp: false, nat: NatNone),
      metricsAddress: parseIpAddress("127.0.0.1"),
      persistenceCmd: PersistenceCmd.prover,
      marketplaceAddress: EthAddress.example.some,
      proverBackendCmd: ProverBackendCmd.nimGroth16,
      # Set the circuitDir such that the tests/circuits/fixtures/ files
      # will be picked up as local files:
      circuitDir: OutDir("tests/circuits/fixtures"),
    )

    check:
      getGraphFile(config).tryGet == config.circuitDir / "proof_main.bin"
      getR1csFile(config).tryGet == config.circuitDir / "proof_main.r1cs"
      getZKeyFile(config).tryGet == config.circuitDir / "proof_main.zkey"

  test "Should suggest usage of downloader tool when files not available":
    let
      config = CodexConf(
        cmd: StartUpCmd.persistence,
        nat: NatConfig(hasExtIp: false, nat: NatNone),
        metricsAddress: parseIpAddress("127.0.0.1"),
        persistenceCmd: PersistenceCmd.prover,
        proverBackendCmd: ProverBackendCmd.nimGroth16,
        marketplaceAddress: EthAddress.example.some,
        circuitDir: OutDir(circuitDir),
      )
      proverResult = config.initializeProver(Taskpool.new())

    check:
      proverResult.isErr
