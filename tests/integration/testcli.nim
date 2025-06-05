import std/tempfiles
import codex/conf
import codex/utils/fileutils
import ../asynctest
import ../checktest
import ./codexprocess
import ./nodeprocess
import ./utils
import ../examples

const HardhatPort {.intdefine.}: int = 8545

asyncchecksuite "Command line interface":
  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  var nodeCount = -1
  proc startCodex(args: seq[string]): Future[CodexProcess] {.async.} =
    return await CodexProcess.startNode(args, false, "cli-test-node")
    inc nodeCount
    return await CodexProcess.startNode(
      args.concat(
        @[
          "--api-port=" & $(await nextFreePort(8080 + nodeCount)),
          "--disc-port=" & $(await nextFreePort(8090 + nodeCount))
        ]
      ),
      true,
      "cli-test-node",
    )

  test "complains when persistence is enabled without ethereum account":
    let node = await startCodex(@["persistence"])
    await node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")
    await node.stop(expectedErrCode = 1)

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = await startCodex(
      @[
        "persistence",
        "--eth-provider=" & "http://127.0.0.1:" & $HardhatPort,
        "--eth-private-key=" & unsafeKeyFile
      ]
    )
    await node.waitUntilOutput(
      "Ethereum private key file does not have safe file permissions"
    )
    await node.stop(expectedErrCode = 1)
    discard removeFile(unsafeKeyFile)

  let
    marketplaceArg = "--marketplace-address=" & $EthAddress.example
    expectedDownloadInstruction =
      "Proving circuit files are not found. Please run the following to download them:"

  test "suggests downloading of circuit files when persistence is enabled without accessible r1cs file":
    let node = await startCodex(@["persistence", "prover", marketplaceArg])
    await node.waitUntilOutput(expectedDownloadInstruction)
    await node.stop(expectedErrCode = 1)

  test "suggests downloading of circuit files when persistence is enabled without accessible wasm file":
  let node = await startCodex(@[
    "persistence",ß
    "--eth-provider=" & "http://127.0.0.1:" & $HardhatPort,
    "prover",
    marketplaceArg,
    "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs"
  ])
    await node.waitUntilOutput(expectedDownloadInstruction)
    await node.stop(expectedErrCode = 1)

  test "suggests downloading of circuit files when persistence is enabled without accessible zkey file":
    let node = await startCodex(@[
      "persistence",
      "--eth-provider=" & "http://127.0.0.1:" & $HardhatPort,
      "prover",
      marketplaceArg,
      "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      "--circom-wasm=tests/circuits/fixtures/proof_main.wasm"
    ])
    await node.waitUntilOutput(expectedDownloadInstruction)
    await node.stop(expectedErrCode = 1)
