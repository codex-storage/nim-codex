import pkg/chronos
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import pkg/codex/utils/json
import ./multinodes

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
        let provider = providers()[i].node.client

        discard provider.postAvailability(
          size=datasetSize.u256, # should match 1 slot only
          duration=duration.u256,
          minPrice=300.u256,
          maxCollateral=200.u256
        )

    proc requestStorage(client: CodexClient,
                        cid: Cid,
                        proofProbability: uint64 = 1,
                        duration: uint64 = 12.periods,
                        reward = 400.u256,
                        collateral = 100.u256,
                        expiry: uint64 = 4.periods,
                        nodes = providers().len,
                        tolerance = 0): Future[PurchaseId] {.async.} =

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
          await advanceToNextPeriod()
          await sleepAsync(every)
      except CancelledError:
        discard

    setup:
      echo ">>> [marketplacesuite.setup] setup start"
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      echo ">>> [marketplacesuite.setup] setup 1"
      let tokenAddress = await marketplace.token()
      echo ">>> [marketplacesuite.setup] setup 2"
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      echo ">>> [marketplacesuite.setup] setup 3"
      let config = await mp.config(marketplace)
      echo ">>> [marketplacesuite.setup] setup 4"
      period = config.proofs.period.truncate(uint64)
      echo ">>> [marketplacesuite.setup] setup 5"
      periodicity = Periodicity(seconds: period.u256)
      echo ">>> [marketplacesuite.setup] setup 6"

      when defined(windows):
        let millis = chronos.millis(500)
      else:
        let millis = chronos.millis(1000)
      continuousMineFut = continuouslyAdvanceEvery(millis)
      echo ">>> [marketplacesuite.setup] setup 7"

    teardown:
      echo ">>> [marketplacesuite.teardown] teardown start"
      await continuousMineFut.cancelAndWait()
      echo ">>> [marketplacesuite.teardown] teardown end"

    body
