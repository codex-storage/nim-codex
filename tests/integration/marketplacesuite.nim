import pkg/chronos
import pkg/ethers/erc20 except `%`
from pkg/libp2p import Cid
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import pkg/codex/utils/json
import ./multinodes
import ../contracts/time
import ../contracts/deployment

export mp
export multinodes

template marketplacesuite*(name: string, body: untyped) =

  multinodesuite name:

    var marketplace {.inject, used.}: Marketplace
    var period: uint64
    var periodicity: Periodicity
    var token {.inject, used.}: Erc20Token
    var continuousMineFut: Future[void]

    proc getCurrentPeriod(): Future[Period] {.async.} =
      return periodicity.periodOf(await ethProvider.currentTime())

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period.u256)
      let currentTime = await ethProvider.currentTime()
      let currentPeriod = periodicity.periodOf(currentTime)
      let endOfPeriod = periodicity.periodEnd(currentPeriod)
      await ethProvider.advanceTimeTo(endOfPeriod + 1)

    template eventuallyP(condition: untyped, finalPeriod: Period): bool =

      proc eventuallyP: Future[bool] {.async.} =
        while(
          let currentPeriod = await getCurrentPeriod();
          currentPeriod <= finalPeriod
        ):
          if condition:
            return true
          await sleepAsync(1.millis)
        return condition

      await eventuallyP()

    proc periods(p: int): uint64 =
      p.uint64 * period

    proc createAvailabilities(datasetSize: int, duration: uint64) =
      # post availability to each provider
      for i in 0..<providers().len:
        let provider = providers()[i].client

        discard provider.postAvailability(
          size=datasetSize.u256, # should match 1 slot only
          duration=duration.u256,
          minPrice=300.u256,
          maxCollateral=200.u256
        )

    proc validateRequest(nodes, tolerance, origDatasetSizeInBlocks: int) =
      if nodes > 1:
        doAssert(origDatasetSizeInBlocks >= 3,
                  "dataset size must be greater than or equal to 3 blocks with " &
                  "more than one node")

    proc requestStorage(client: CodexClient,
                        cid: Cid,
                        proofProbability = 3,
                        duration: uint64 = 12.periods,
                        reward = 400.u256,
                        collateral = 100.u256,
                        expiry: uint64 = 4.periods,
                        nodes = providers().len,
                        tolerance = 0,
                        origDatasetSizeInBlocks: int): Future[PurchaseId] {.async.} =

      validateRequest(nodes, tolerance, origDatasetSizeInBlocks)

      let expiry = (await ethProvider.currentTime()) + expiry.u256

      let id = client.requestStorage(
        cid,
        expiry=expiry,
        duration=duration.u256,
        proofProbability=proofProbability.u256,
        collateral=collateral,
        reward=reward,
        nodes=nodes.uint,
        tolerance=tolerance.uint
      ).get

      return id

    proc continuouslyAdvanceEvery(every: chronos.Duration) {.async.} =
      try:
        while true:
          trace "advancing to next period"
          await advanceToNextPeriod()
          await sleepAsync(every)
      except CancelledError:
        discard

    proc startIntervalMining(intervalMillis: int) {.async.} =
      discard await ethProvider.send("evm_setIntervalMining", @[%intervalMillis])

    proc changePeriodAdvancementTo(intervalMillis: int) {.async.} =
      if not continuousMineFut.isNil and not continuousMineFut.finished:
        await continuousMineFut.cancelAndWait()
      continuousMineFut = continuouslyAdvanceEvery(intervalMillis.millis)

    proc waitForAllSlotsFilled(
      slotSize: int,
      availabilityDuration: uint64,
      timeout = 2.periods): Future[seq[SlotId]] {.async.} =
      ## temporary workaround for the slot queue not being able to re-process
      ## items in the queue if it did not have enough avaialability
      ## Setup:
      ## A host has availability to fill one slot (only that specific amount of
      ## bytes are in the availability). When a host downloads and attempts to
      ## fill a slot, it means it would have looked at all the other slots and
      ## discarded them from the slot queue as it would not have had enough
      ## availability to service them. If downloaded and proved slot is already
      ## filled by another host, the bytes downloaded should be returned to the
      ## availability so that it can download another slot. Additionally, the
      ## node should be able to look at the other unfilled slots in the request
      ## again.

      var filledSlotIds: seq[SlotId] = @[]

      proc onSlotFilled(event: SlotFilled) =
        let slotId = slotId(event.requestId, event.slotIndex)
        filledSlotIds.add slotId

      let subscription = await marketplace.subscribe(SlotFilled, onSlotFilled)

      var idx = 0
      for provider in providers():
        discard provider.client.postAvailability(
          size=slotSize.u256, # should match 1 slot only
          duration=availabilityDuration.u256,
          minPrice=300.u256,
          maxCollateral=200.u256
        )

        check eventually(filledSlotIds.len > idx, timeout=timeout.int*1000)
        inc idx

      await subscription.unsubscribe()
      return filledSlotIds

    setup:
      # TODO: This is currently the address of the marketplace with a dummy
      # verifier. Use real marketplace address, `Marketplace.address` once we
      # can generate actual Groth16 ZK proofs.
      let marketplaceAddress = Marketplace.address(dummyVerifier = false)
      marketplace = Marketplace.new(marketplaceAddress, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await mp.config(marketplace)
      period = config.proofs.period.truncate(uint64)
      periodicity = Periodicity(seconds: period.u256)

      continuousMineFut = continuouslyAdvanceEvery(chronos.millis(15000))

    teardown:
      if not continuousMineFut.isNil and not continuousMineFut.finished:
        await continuousMineFut.cancelAndWait()

    body
