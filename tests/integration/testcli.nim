import std/tempfiles
import std/appdirs
import std/paths
import codex/conf
import codex/utils/fileutils
import ../asynctest
import ../checktest
import ./codexprocess
import ./nodeprocess
import ../examples

asyncchecksuite "Command line interface":
  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  var tmpDataDir: string
  setup:
    # Ensure the key file is created with safe permissions
    tmpDataDir = createTempDir(prefix = "testcli_", suffix = "", dir = $getTempDir())

  teardown:
    # Remove the temporary data directory after tests
    discard removeDir(tmpDataDir)

  proc startCodex(args: seq[string]): Future[CodexProcess] {.async.} =
    var args = args
    if not args.anyIt(it.contains("--data-dir")):
      args.add("--data-dir=" & tmpDataDir)

    return await CodexProcess.startNode(args, debug = false, "cli-test-node")

  test "complains when persistence is enabled without ethereum account":
    let node = await startCodex(@["persistence"])

    defer:
      await node.stop()

    await node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = await startCodex(@["persistence", "--eth-private-key=" & unsafeKeyFile])

    defer:
      await node.stop()
      discard removeFile(unsafeKeyFile)

    await node.waitUntilOutput(
      "Ethereum private key file does not have safe file permissions"
    )

  let expectedDownloadInstruction =
    "Proving circuit files are not found. Please run the following to download them:"

  test "suggests downloading of circuit files when persistence is enabled without accessible r1cs file":
    let node = await startCodex(
      @[
        "persistence",
        "prover",
        "--marketplace-address=" & $EthAddress.example,
        "--prover-backend=nimgroth16",
      ]
    )

    defer:
      await node.stop()

    await node.waitUntilOutput(expectedDownloadInstruction)

  test "suggests downloading of circuit files when persistence is enabled without accessible zkey file":
    let node = await startCodex(
      @[
        "persistence",
        "prover",
        "--marketplace-address=" & $EthAddress.example,
        "--prover-backend=nimgroth16",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      ]
    )

    defer:
      await node.stop()

    await node.waitUntilOutput(expectedDownloadInstruction)

  test "suggests downloading of circuit files when persistence is enabled without accessible graph file":
    let node = await startCodex(
      @[
        "persistence",
        "prover",
        "--marketplace-address=" & $EthAddress.example,
        "--prover-backend=nimgroth16",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
        "--circom-zkey=tests/circuits/fixtures/proof_main.zkey",
      ]
    )

    defer:
      await node.stop()

    await node.waitUntilOutput(expectedDownloadInstruction)
