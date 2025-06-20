import std/tempfiles
import std/times
import std/appdirs
import std/paths
import codex/conf
import codex/utils/fileutils
import ../asynctest
import ../checktest
import ./codexprocess
import ./nodeprocess
import ./utils
import ../examples

const HardhatPort {.intdefine.}: int = 8545
const CodexApiPort {.intdefine.}: int = 8080
const CodexDiscPort {.intdefine.}: int = 8090
const CodexLogToFile {.booldefine.}: bool = false
const CodexLogLevel {.strdefine.}: string = ""
const CodexLogsDir {.strdefine.}: string = ""

asyncchecksuite "Command line interface":
  let startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  let key = "4242424242424242424242424242424242424242424242424242424242424242"

  var currentTestName = ""
  var testCount = 0
  var nodeCount = 0

  template test(tname, tbody) =
    inc testCount
    currentTestName = tname
    test tname:
      tbody

  proc addLogFile(args: seq[string]): seq[string] =
    var args = args
    when CodexLogToFile:
      args.add(
        "--log-file=" &
          getLogFile(
            CodexLogsDir,
            startTime,
            "Command line interface",
            currentTestName,
            "Client",
            some nodeCount mod testCount,
          )
      )
    when CodexLogLevel != "":
      args.add "--log-level=" & CodexLogLevel

    return args

  proc startCodex(arguments: seq[string]): Future[CodexProcess] {.async.} =
    inc nodeCount
    let args = arguments.addLogFile
    return await CodexProcess.startNode(
      args.concat(
        @[
          "--api-port=" & $(await nextFreePort(CodexApiPort + nodeCount)),
          "--disc-port=" & $(await nextFreePort(CodexDiscPort + nodeCount)),
        ]
      ),
      debug = false,
      "cli-test-node",
    )

  test "complains when persistence is enabled without ethereum account":
    # let hardhat = await HardhatProcess.startNode(@[], true, "hardhat")
    let node = await startCodex(@["persistence"])

    defer:
      await node.stop(expectedErrCode = 1)

    await node.waitUntilOutput("Persistence enabled, but no Ethereum account was set")

  test "complains when ethereum private key file has wrong permissions":
    let unsafeKeyFile = genTempPath("", "")
    discard unsafeKeyFile.writeFile(key, 0o666)
    let node = await startCodex(
      @[
        "persistence",
        "--eth-provider=" & "ws://localhost:" & $HardhatPort,
        "--eth-private-key=" & unsafeKeyFile,
      ]
    )

    defer:
      await node.stop(expectedErrCode = 1)
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
      await node.stop(expectedErrCode = 1)

    await node.waitUntilOutput(expectedDownloadInstruction)

  test "suggests downloading of circuit files when persistence is enabled without accessible zkey file":
    let node = await startCodex(
      @[
        "persistence",
        "--eth-provider=" & "ws://localhost:" & $HardhatPort,

        "prover",

        "--marketplace-address=" & $EthAddress.example,
        "--prover-backend=nimgroth16",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
      ]
    )

    defer:
      await node.stop(expectedErrCode = 1)

    await node.waitUntilOutput(expectedDownloadInstruction)

  test "suggests downloading of circuit files when persistence is enabled without accessible graph file":
    let node = await startCodex(
      @[
        "persistence",
        "--eth-provider=" & "ws://localhost:" & $HardhatPort,
        "prover",
        "--marketplace-address=" & $EthAddress.example,
        "--prover-backend=nimgroth16",
        "--circom-r1cs=tests/circuits/fixtures/proof_main.r1cs",
        "--circom-zkey=tests/circuits/fixtures/proof_main.zkey",
      ]
    )

    defer:
      await node.stop(expectedErrCode = 1)

    await node.waitUntilOutput(expectedDownloadInstruction)
