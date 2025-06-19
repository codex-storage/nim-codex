from std/times import inMilliseconds, initDuration, inSeconds, fromUnix
import std/sugar
import pkg/codex/logutils
import pkg/questionable/results
import pkg/ethers/provider
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite
import ./nodeconfigs

export logutils

logScope:
  topics = "integration test validation"

marketplacesuite(name = "Validation", stopOnRequestFail = false):
  const blocks = 8
  const ecNodes = 3
  const ecTolerance = 1
  const proofProbability = 1.u256

  const collateralPerByte = 1.u256
  const minPricePerBytePerSecond = 1.u256

  test "validator marks proofs as missing when using validation groups",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      hardhat: HardhatConfig.none,
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug() # uncomment to enable console log output
        .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain").some,
      providers: CodexConfigs
        .init(nodes = 1)
        .withSimulateProofFailures(idx = 0, failEveryNProofs = 1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some,
      validators: CodexConfigs
        .init(nodes = 2)
        .withValidationGroups(groups = 2)
        .withValidationGroupIndex(idx = 0, groupIndex = 0)
        .withValidationGroupIndex(idx = 1, groupIndex = 1)
        # .debug() # uncomment to enable console log output
        .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("validator")
        # each topic as a separate string argument
        .some,
    ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    # let mine a block to sync the blocktime with the current clock
    discard await ethProvider.send("evm_mine")

    var currentTime = await ethProvider.currentTime()
    let requestEndTime = currentTime.truncate(uint64) + duration

    let data = await RandomChunker.example(blocks = blocks)
    let datasetSize =
      datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)
    await createAvailabilities(
      datasetSize.truncate(uint64),
      duration,
      collateralPerByte,
      minPricePerBytePerSecond,
    )

    let cid = (await client0.upload(data)).get
    let purchaseId = await client0.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = proofProbability,
    )
    let requestId = (await client0.requestId(purchaseId)).get

    debug "validation suite", purchaseId = purchaseId.toHex, requestId = requestId

    discard await waitForRequestToStart(expiry.int + 60)

    discard await ethProvider.send("evm_mine")
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds

    discard await waitForRequestToFail(secondsTillRequestEnd + 60)

  test "validator uses historical state to mark missing proofs",
    NodeConfigs(
      # Uncomment to start Hardhat automatically, typically so logs can be inspected locally
      hardhat: HardhatConfig.none,
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug() # uncomment to enable console log output
        .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("purchases", "onchain").some,
      providers: CodexConfigs
        .init(nodes = 1)
        .withSimulateProofFailures(idx = 0, failEveryNProofs = 1)
        # .debug() # uncomment to enable console log output
        # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("sales", "onchain")
        .some,
    ):
    let client0 = clients()[0].client
    let expiry = 5.periods
    let duration = expiry + 10.periods

    # let mine a block to sync the blocktime with the current clock
    discard await ethProvider.send("evm_mine")

    var currentTime = await ethProvider.currentTime()
    let requestEndTime = currentTime.truncate(uint64) + duration

    let data = await RandomChunker.example(blocks = blocks)
    let datasetSize =
      datasetSize(blocks = blocks, nodes = ecNodes, tolerance = ecTolerance)
    await createAvailabilities(
      datasetSize.truncate(uint64),
      duration,
      collateralPerByte,
      minPricePerBytePerSecond,
    )

    let cid = (await client0.upload(data)).get
    let purchaseId = await client0.requestStorage(
      cid,
      expiry = expiry,
      duration = duration,
      nodes = ecNodes,
      tolerance = ecTolerance,
      proofProbability = proofProbability,
    )
    let requestId = (await client0.requestId(purchaseId)).get

    debug "validation suite", purchaseId = purchaseId.toHex, requestId = requestId

    discard await waitForRequestToStart(expiry.int + 60)

    # extra block just to make sure we have one that separates us
    # from the block containing the last (past) SlotFilled event
    discard await ethProvider.send("evm_mine")

    var validators = CodexConfigs
      .init(nodes = 2)
      .withValidationGroups(groups = 2)
      .withValidationGroupIndex(idx = 0, groupIndex = 0)
      .withValidationGroupIndex(idx = 1, groupIndex = 1)
      # .debug() # uncomment to enable console log output
      .withLogFile()
      # uncomment to output log file to: # tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
      .withLogTopics("validator") # each topic as a separate string argument

    failAndTeardownOnError "failed to start validator nodes":
      for config in validators.configs.mitems:
        let node = await startValidatorNode(config)
        running.add RunningNode(role: Role.Validator, node: node)

    discard await ethProvider.send("evm_mine")
    currentTime = await ethProvider.currentTime()
    let secondsTillRequestEnd = (requestEndTime - currentTime.truncate(uint64)).int

    debug "validation suite", secondsTillRequestEnd = secondsTillRequestEnd.seconds

    discard await waitForRequestToFail(secondsTillRequestEnd + 60)
