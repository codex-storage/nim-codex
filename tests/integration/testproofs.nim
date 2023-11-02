# import std/sequtils
# import std/os
from std/times import inMilliseconds
import pkg/chronicles
import pkg/stew/byteutils
# import pkg/codex/contracts
# import pkg/codex/periods
import ../contracts/time
import ../contracts/deployment
import ../codex/helpers
import ../examples
# import ./twonodes
import ./marketplacesuite

export chronicles

logScope:
  topics = "integration test proofs"

# twonodessuite "Proving integration test", debug1=false, debug2=false:
#   let validatorDir = getTempDir() / "CodexValidator"

#   var marketplace: Marketplace
#   var period: uint64

#   proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
#     client.getPurchase(id).option.?state == some state

#   setup:
#     marketplace = Marketplace.new(Marketplace.address, provider)
#     period = (await marketplace.config()).proofs.period.truncate(uint64)

#     # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
#     # advanced until blocks are mined and that happens only when transaction is submitted.
#     # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
#     await provider.advanceTime(1.u256)

#   proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 3,
#                                   duration: uint64 = 100 * period,
#                                   expiry: uint64 = 30) {.async.} =
#     discard client2.postAvailability(
#       size=0xFFFFF.u256,
#       duration=duration.u256,
#       minPrice=300.u256,
#       maxCollateral=200.u256
#     )
#     let cid = client1.upload("some file contents").get
#     let expiry = (await provider.currentTime()) + expiry.u256
#     let id = client1.requestStorage(
#       cid,
#       expiry=expiry,
#       duration=duration.u256,
#       proofProbability=proofProbability.u256,
#       collateral=100.u256,
#       reward=400.u256
#     ).get
#     check eventually client1.purchaseStateIs(id, "started")

#   proc advanceToNextPeriod {.async.} =
#     let periodicity = Periodicity(seconds: period.u256)
#     let currentPeriod = periodicity.periodOf(await provider.currentTime())
#     let endOfPeriod = periodicity.periodEnd(currentPeriod)
#     await provider.advanceTimeTo(endOfPeriod + 1)

#   proc startValidator: NodeProcess =
#     startNode([
#       "--data-dir=" & validatorDir,
#       "--api-port=8089",
#       "--disc-port=8099",
#       "--listen-addrs=/ip4/127.0.0.1/tcp/0",
#       "--validator",
#       "--eth-account=" & $accounts[2]
#     ], debug = false)

#   proc stopValidator(node: NodeProcess) =
#     node.stop()
#     removeDir(validatorDir)

#   test "hosts submit periodic proofs for slots they fill":
#     await waitUntilPurchaseIsStarted(proofProbability=1)
#     var proofWasSubmitted = false
#     proc onProofSubmitted(event: ProofSubmitted) =
#       proofWasSubmitted = true
#     let subscription = await marketplace.subscribe(ProofSubmitted, onProofSubmitted)
#     await provider.advanceTime(period.u256)
#     check eventually proofWasSubmitted
#     await subscription.unsubscribe()

#   test "validator will mark proofs as missing":
#     let validator = startValidator()
#     await waitUntilPurchaseIsStarted(proofProbability=1)

#     node2.stop()

#     var slotWasFreed = false
#     proc onSlotFreed(event: SlotFreed) =
#       slotWasFreed = true
#     let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

#     for _ in 0..<100:
#       if slotWasFreed:
#         break
#       else:
#         await advanceToNextPeriod()
#         await sleepAsync(1.seconds)

#     check slotWasFreed

#     await subscription.unsubscribe()
#     stopValidator(validator)

# multinodesuite "Simulate invalid proofs",
#   Nodes.init(clients=1, providers=0, validators=1),
#   DebugConfig.init(client=false, provider=false, validator=false):
#     # .simulateProofFailuresFor(providerIdx = 0, failEveryNProofs = 2),

#   proc purchaseStateIs(client: CodexClient, id: PurchaseId, state: string): bool =
#     client.getPurchase(id).option.?state == some state

#   var marketplace: Marketplace
#   var period: uint64
#   var slotId: SlotId

#   setup:
#     marketplace = Marketplace.new(Marketplace.address, provider)
#     let config = await marketplace.config()
#     period = config.proofs.period.truncate(uint64)
#     slotId = SlotId(array[32, byte].default) # ensure we aren't reusing from prev test

#     # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
#     # advanced until blocks are mined and that happens only when transaction is submitted.
#     # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
#     await provider.advanceTime(1.u256)

#   proc periods(p: int): uint64 =
#     p.uint64 * period

#   proc advanceToNextPeriod {.async.} =
#     let periodicity = Periodicity(seconds: period.u256)
#     let currentPeriod = periodicity.periodOf(await provider.currentTime())
#     let endOfPeriod = periodicity.periodEnd(currentPeriod)
#     await provider.advanceTimeTo(endOfPeriod + 1)

#   proc waitUntilPurchaseIsStarted(proofProbability: uint64 = 1,
#                                   duration: uint64 = 12.periods,
#                                   expiry: uint64 = 4.periods) {.async.} =

#     if clients().len < 1 or providers().len < 1:
#       raiseAssert("must start at least one client and one provider")

#     let client = clients()[0].restClient
#     let storageProvider = providers()[0].restClient

#     discard storageProvider.postAvailability(
#       size=0xFFFFF.u256,
#       duration=duration.u256,
#       minPrice=300.u256,
#       maxCollateral=200.u256
#     )
#     let cid = client.upload("some file contents " & $ getTime().toUnix).get
#     let expiry = (await provider.currentTime()) + expiry.u256
#     # avoid timing issues by filling the slot at the start of the next period
#     await advanceToNextPeriod()
#     let id = client.requestStorage(
#       cid,
#       expiry=expiry,
#       duration=duration.u256,
#       proofProbability=proofProbability.u256,
#       collateral=100.u256,
#       reward=400.u256
#     ).get
#     check eventually client.purchaseStateIs(id, "started")
#     let purchase = client.getPurchase(id).get
#     slotId = slotId(purchase.requestId, 0.u256)

#   # TODO: these are very loose tests in that they are not testing EXACTLY how
#   # proofs were marked as missed by the validator. These tests should be
#   # tightened so that they are showing, as an integration test, that specific
#   # proofs are being marked as missed by the validator.

#   test "slot is freed after too many invalid proofs submitted":
#     let failEveryNProofs = 2
#     let totalProofs = 100

#     startProviderNode(@[
#       CliOption(
#         nodeIdx: 0,
#         key: "--simulate-proof-failures",
#         value: $failEveryNProofs
#       )
#     ])

#     await waitUntilPurchaseIsStarted(duration=totalProofs.periods)

#     var slotWasFreed = false
#     proc onSlotFreed(event: SlotFreed) =
#       if slotId(event.requestId, event.slotIndex) == slotId:
#         slotWasFreed = true
#     let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

#     for _ in 0..<totalProofs:
#       if slotWasFreed:
#         break
#       else:
#         await advanceToNextPeriod()
#         await sleepAsync(1.seconds)

#     check slotWasFreed

#     await subscription.unsubscribe()

#   test "slot is not freed when not enough invalid proofs submitted":
#     let failEveryNProofs = 3
#     let totalProofs = 12
#     startProviderNode(@[
#       CliOption(
#         nodeIdx: 0,
#         key: "--simulate-proof-failures",
#         value: $failEveryNProofs
#       )
#     ])

#     await waitUntilPurchaseIsStarted(duration=totalProofs.periods)

#     var slotWasFreed = false
#     proc onSlotFreed(event: SlotFreed) =
#       if slotId(event.requestId, event.slotIndex) == slotId:
#         slotWasFreed = true
#     let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

#     for _ in 0..<totalProofs:
#       if slotWasFreed:
#         break
#       else:
#         await advanceToNextPeriod()
#         await sleepAsync(1.seconds)

#     check not slotWasFreed

#     await subscription.unsubscribe()




# marketplacesuite "Simulate invalid proofs - 1 provider node",
#   Nodes(
#     hardhat: HardhatConfig()
#               .withLogFile(),

#     clients: NodeConfig()
#               .nodes(1)
#               .debug()
#               .withLogFile()
#               .withLogTopics("node"),

#     providers: NodeConfig()
#                 .nodes(1)
#                 .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=1)
#                 .debug()
#                 .withLogFile()
#                 .withLogTopics(
#                   "marketplace",
#                   "sales",
#                   "reservations",
#                   "node",
#                   "JSONRPC-HTTP-CLIENT",
#                   "JSONRPC-WS-CLIENT",
#                   "ethers",
#                   "restapi",
#                   "clock"
#                 ),

#     validators: NodeConfig()
#                   .nodes(1)
#                   .withLogFile()
#                   .debug()
#                   .withLogTopics("validator", "initial-proving", "proving", "clock", "onchain", "ethers")
#   ):

#     test "slot is freed after too many invalid proofs submitted":
#       let client0 = clients()[0].node.client
#       let totalProofs = 50

#       let data = byteutils.toHex(await exampleData())
#       createAvailabilities(data.len, totalProofs.periods)

#       let cid = client0.upload(data).get

#       let purchaseId = await client0.requestStorage(cid, duration=totalProofs.periods)
#       let requestId = client0.requestId(purchaseId).get

#       check eventually client0.purchaseStateIs(purchaseId, "started")

#       var slotWasFreed = false
#       proc onSlotFreed(event: SlotFreed) {.gcsafe, upraises:[].} =
#         if event.requestId == requestId and
#            event.slotIndex == 0.u256: # assume only one slot, so index 0
#           slotWasFreed = true

#       let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

#       echo "waiting for proofs ", totalProofs
#       # check eventuallyP(slotWasFreed, totalProofs, 1.periods.int)
#       check eventually(slotWasFreed, totalProofs.periods.int * 1000)
#       echo "got to the end... freed: ", slotWasFreed

#       echo "unsubscribing from slotFreed"
#       await subscription.unsubscribe()
#       echo "unsubscribed from slotFreed"

# marketplacesuite "Simulate invalid proofs - 1 provider node",
#   Nodes(
#     hardhat: HardhatConfig()
#               .withLogFile(),

#     clients: NodeConfig()
#               .nodes(1)
#               .debug()
#               .withLogFile()
#               .withLogTopics("node"),

#     providers: NodeConfig()
#                 .nodes(1)
#                 .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=3)
#                 .debug()
#                 .withLogFile()
#                 .withLogTopics(
#                   "marketplace",
#                   "sales",
#                   "reservations",
#                   "node",
#                   "JSONRPC-HTTP-CLIENT",
#                   "JSONRPC-WS-CLIENT",
#                   "ethers",
#                   "restapi",
#                   "clock"
#                 ),

#     validators: NodeConfig()
#                   .nodes(1)
#                   .withLogFile()
#                   .withLogTopics("validator", "initial-proving", "proving", "clock", "onchain", "ethers")
#   ):

#     test "slot is not freed when not enough invalid proofs submitted":
#       let client0 = clients()[0].node.client
#       let totalProofs = 25

#       let data = byteutils.toHex(await exampleData())
#       createAvailabilities(data.len, totalProofs.periods)

#       let cid = client0.upload(data).get

#       let purchaseId = await client0.requestStorage(cid, duration=totalProofs.periods)
#       let requestId = client0.requestId(purchaseId).get

#       check eventually client0.purchaseStateIs(purchaseId, "started")

#       var slotWasFreed = false
#       proc onSlotFreed(event: SlotFreed) {.gcsafe, upraises:[].} =
#         if event.requestId == requestId and
#            event.slotIndex == 0.u256: # assume only one slot, so index 0
#           slotWasFreed = true

#       let subscription = await marketplace.subscribe(SlotFreed, onSlotFreed)

#       echo "waiting for proofs: ", totalProofs
#       # let freed = eventuallyP(slotWasFreed, totalProofs, 1.periods.int)
#       # echo "got to the end... freed: ", freed
#       # check not freed
#       check not eventually(slotWasFreed, totalProofs.periods.int * 1000)

#       echo "unsubscribing from slotFreed"
#       await subscription.unsubscribe()
#       echo "unsubscribed from slotFreed"

marketplacesuite "Simulate invalid proofs",
  Nodes(
    hardhat: HardhatConfig()
              .withLogFile(),

    clients: NodeConfig()
              .nodes(1)
              .debug()
              .withLogFile()
              .withLogTopics("node", "erasure"),

    providers: NodeConfig()
                .nodes(2)
                .simulateProofFailuresFor(providerIdx=0, failEveryNProofs=2)
                .debug()
                .withLogFile()
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
                  .withLogFile()
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
    let totalProofs = 25

    let data = byteutils.toHex(await exampleData())
    # createAvailabilities(data.len, totalProofs.periods)

    discard provider0.node.client.postAvailability(
      size=data.len.u256, # should match 1 slot only
      duration=totalProofs.periods.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )

    let cid = client0.upload(data).get

    let purchaseId = await client0.requestStorage(
      cid,
      duration=totalProofs.periods,
      # tolerance=1
    )

    without requestId =? client0.requestId(purchaseId):
      fail()


    var provider0slotIndex = none UInt256
    proc onSlotFilled(event: SlotFilled) {.upraises:[].} =
      provider0slotIndex = some event.slotIndex

    let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

    # wait til first slot is filled
    check eventually provider0slotIndex.isSome



    # await sleepAsync(1.seconds) # allow time for provider0 to fill a slot

    # now add availability for provider1, which should allow provider1 to put
    # the remaining slot in its queue
    discard provider1.node.client.postAvailability(
      size=data.len.u256, # should match 1 slot only
      duration=totalProofs.periods.u256,
      minPrice=300.u256,
      maxCollateral=200.u256
    )
    let provider1slotIndex = if provider0slotIndex == some 0.u256: 1.u256 else: 0.u256
    echo "PROVIDER 0 SLOT INDEX: ", provider0slotIndex
    echo "PROVIDER 1 SLOT INDEX: ", provider1slotIndex
    let provider0slotId = slotId(requestId, !provider0slotIndex)
    let provider1slotId = slotId(requestId, provider1slotIndex)

    # wait til second slot is filled
    check eventually provider1.node.client.saleStateIs(provider1slotId, "SaleFilled")

    check eventually client0.purchaseStateIs(purchaseId, "started")

    let currentPeriod = await getCurrentPeriod()
    let timeUtil = await timeUntil(currentPeriod + totalProofs.u256 + 1)
    # check eventually(
    #   client0.purchaseStateIs(purchaseId, "finished"),
    #   timeUtil.inMilliseconds.int)
    check eventually(
      provider0.node.client.saleStateIs(provider0slotId, "SaleFinished"),
      timeUtil.inMilliseconds.int)

    check eventually(
      provider1.node.client.saleStateIs(provider1slotId, "SaleFinished"),
      timeUtil.inMilliseconds.int)

    check eventually(
      (await token.balanceOf(!provider1.address)) >
      (await token.balanceOf(!provider0.address))
    )
    echo "provider1 balance: ", (await token.balanceOf(!provider1.address))
    echo "provider0 balance: ", (await token.balanceOf(!provider0.address))

    await subscription.unsubscribe()
