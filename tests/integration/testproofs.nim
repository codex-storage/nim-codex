from std/times import inMilliseconds
import pkg/chronicles
import pkg/stew/byteutils
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
import ./marketplacesuite

export chronicles

logScope:
  topics = "integration test proofs"

marketplacesuite "Simulate invalid proofs, 1 provider node, every proof invalid",
  Nodes(
    # Uncomment to start Hardhat automatically, mainly so logs can be inspected locally
    # hardhat: HardhatConfig()
    #           .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log,

    clients: NodeConfig()
              .nodes(1)
              # .debug() # uncomment to enable console log output
              # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
              .withLogTopics("node"),

    providers: NodeConfig()
                .nodes(1)
                .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=1)
                # .debug() # uncomment to enable console log output
                # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                .withLogTopics(
                  "marketplace",
                  "sales",
                  "reservations",
                  "node",
                  "JSONRPC-HTTP-CLIENT",
                  "JSONRPC-WS-CLIENT",
                  "ethers",
                  "restapi",
                  "clock"
                ),

    validators: NodeConfig()
                  .nodes(1)
                  # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                  # .debug() # uncomment to enable console log output
                  .withLogTopics("validator", "initial-proving", "proving", "clock", "onchain", "ethers")
  ):

    test "slot is freed after too many invalid proofs submitted":
      let client0 = clients()[0].node.client
      let totalPeriods = 50

      let data = byteutils.toHex(await exampleData())
      createAvailabilities(data.len, totalPeriods.periods)

      let cid = client0.upload(data).get

      let purchaseId = await client0.requestStorage(cid, duration=totalPeriods.periods)
      let requestId = client0.requestId(purchaseId).get

      check eventually client0.purchaseStateIs(purchaseId, "started")

      var slotWasFreed = false
      proc onSlotFreed(event: SlotFreed) {.gcsafe, upraises:[].} =
        if event.requestId == requestId and
          event.slotIndex == 0.u256: # assume only one slot, so index 0
          slotWasFreed = true

      let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

      let currentPeriod = await getCurrentPeriod()
      check eventuallyP(slotWasFreed, currentPeriod + totalPeriods.u256 + 1)

      await subscription.unsubscribe()

marketplacesuite "Simulate invalid proofs, 1 provider node, every 3rd proof invalid",
  Nodes(
    # Uncomment to start Hardhat automatically, mainly so logs can be inspected locally
    # hardhat: HardhatConfig()
    #           .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log,

    clients: NodeConfig()
              .nodes(1)
              # .debug() # uncomment to enable console log output
              # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
              .withLogTopics("node"),

    providers: NodeConfig()
                .nodes(1)
                .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=3)
                # .debug() # uncomment to enable console log output
                # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                .withLogTopics(
                  "marketplace",
                  "sales",
                  "reservations",
                  "node",
                  "JSONRPC-HTTP-CLIENT",
                  "JSONRPC-WS-CLIENT",
                  "ethers",
                  "restapi",
                  "clock"
                ),

    validators: NodeConfig()
                  .nodes(1)
                  # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                  .withLogTopics("validator", "initial-proving", "proving", "clock", "onchain", "ethers")
  ):

    test "hosts submit periodic proofs for slots they fill":
      let client0 = clients()[0].node.client
      let totalPeriods = 50

      let data = byteutils.toHex(await exampleData())
      createAvailabilities(data.len, totalPeriods.periods)

      let cid = client0.upload(data).get

      let purchaseId = await client0.requestStorage(cid, duration=totalPeriods.periods)
      check eventually client0.purchaseStateIs(purchaseId, "started")

      var proofWasSubmitted = false
      proc onProofSubmitted(event: ProofSubmitted) =
        proofWasSubmitted = true

      let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)

      let currentPeriod = await getCurrentPeriod()
      check eventuallyP(proofWasSubmitted, currentPeriod + totalPeriods.u256 + 1)

      await subscription.unsubscribe()

    test "slot is not freed when not enough invalid proofs submitted":
      let client0 = clients()[0].node.client
      let totalPeriods = 25

      let data = byteutils.toHex(await exampleData())
      createAvailabilities(data.len, totalPeriods.periods)

      let cid = client0.upload(data).get

      let purchaseId = await client0.requestStorage(cid, duration=totalPeriods.periods)
      let requestId = client0.requestId(purchaseId).get

      check eventually client0.purchaseStateIs(purchaseId, "started")

      var slotWasFreed = false
      proc onSlotFreed(event: SlotFreed) {.gcsafe, upraises:[].} =
        if event.requestId == requestId and
           event.slotIndex == 0.u256: # assume only one slot, so index 0
          slotWasFreed = true

      let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

      # check not freed
      let currentPeriod = await getCurrentPeriod()
      check not eventuallyP(slotWasFreed, currentPeriod + totalPeriods.u256 + 1)

      await subscription.unsubscribe()

marketplacesuite "Simulate invalid proofs",
  Nodes(
    # Uncomment to start Hardhat automatically, mainly so logs can be inspected locally
    # hardhat: HardhatConfig()
    #           .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log,

    clients: NodeConfig()
              .nodes(1)
              # .debug() # uncomment to enable console log output.debug()
              # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
              .withLogTopics("node", "erasure"),

    providers: NodeConfig()
                .nodes(2)
                .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=2)
                # .debug() # uncomment to enable console log output
                # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                .withLogTopics(
                  "marketplace",
                  "sales",
                  "reservations",
                  "node",
                  "JSONRPC-HTTP-CLIENT",
                  "JSONRPC-WS-CLIENT",
                  "ethers",
                  "restapi"
                ),

    validators: NodeConfig()
                  .nodes(1)
                  # .withLogFile() # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
                  .withLogTopics("validator", "initial-proving", "proving")
  ):

  # TODO: these are very loose tests in that they are not testing EXACTLY how
  # proofs were marked as missed by the validator. These tests should be
  # tightened so that they are showing, as an integration test, that specific
  # proofs are being marked as missed by the validator.

  test "provider that submits invalid proofs is paid out less":
    let client0 = clients()[0].node.client
    let provider0 = providers()[0]
    let provider1 = providers()[1]
    let totalPeriods = 25

    let data = byteutils.toHex(await exampleData())

    discard provider0.node.client.postAvailability(
      size=data.len.u256, # should match 1 slot only
      duration=totalPeriods.periods.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalPeriods.periods
    )

    without requestId =? client0.requestId(purchaseId):
      fail()


    var provider0slotIndex = none UInt256
    proc onSlotFilled(event: SlotFilled) {.upraises:[].} =
      provider0slotIndex = some event.slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # wait til first slot is filled
    check eventually provider0slotIndex.isSome

    # now add availability for provider1, which should allow provider1 to put
    # the remaining slot in its queue
    discard provider1.node.client.postAvailability(
      size=data.len.u256, # should match 1 slot only
      duration=totalPeriods.periods.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )
    let provider1slotIndex = if provider0slotIndex == some 0.u256: 1.u256 else: 0.u256
    let provider0slotId = slotId(requestId, !provider0slotIndex)
    let provider1slotId = slotId(requestId, provider1slotIndex)

    # Wait til second slot is filled. SaleFilled happens too quickly, check SaleProving instead.
    check eventually provider1.node.client.saleStateIs(provider1slotId, "SaleProving")

    check eventually client0.purchaseStateIs(purchaseId, "started")

    let currentPeriod = await getCurrentPeriod()
    check eventuallyP(
      # SaleFinished happens too quickly, check SalePayout instead
      provider0.node.client.saleStateIs(provider0slotId, "SalePayout"),
      currentPeriod + totalPeriods.u256 + 1)

    check eventuallyP(
      # SaleFinished happens too quickly, check SalePayout instead
      provider1.node.client.saleStateIs(provider1slotId, "SalePayout"),
      currentPeriod + totalPeriods.u256 + 1)

    check eventually(
      (await token.balanceOf(!provider1.address)) >
      (await token.balanceOf(!provider0.address))
    )

    await subscription.unsubscribe()
