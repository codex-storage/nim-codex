import std/times
import pkg/chronos
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import pkg/codex/utils/json
import ./multinodes

export mp
export multinodes

template marketplacesuite*(name: string, startNodes: Nodes, body: untyped) =

  multinodesuite name, startNodes:

    var marketplace {.inject, used.}: Marketplace
    var period: uint64
    var periodicity: Periodicity
    var token {.inject, used.}: Erc20Token

    proc getCurrentPeriod(): Future[Period] {.async.} =
      return periodicity.periodOf(await ethProvider.currentTime())

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period.u256)
      let currentPeriod = periodicity.periodOf(await ethProvider.currentTime())
      let endOfPeriod = periodicity.periodEnd(currentPeriod)
      await ethProvider.advanceTimeTo(endOfPeriod + 1)

    proc timeUntil(period: Period): Future[times.Duration] {.async.} =
      let currentPeriod = await getCurrentPeriod()
      let endOfCurrPeriod = periodicity.periodEnd(currentPeriod)
      let endOfLastPeriod = periodicity.periodEnd(period)
      let endOfCurrPeriodTime = initTime(endOfCurrPeriod.truncate(int64), 0)
      let endOfLastPeriodTime = initTime(endOfLastPeriod.truncate(int64), 0)
      let r = endOfLastPeriodTime - endOfCurrPeriodTime
      return r

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
                        expiry: uint64 = 4.periods,
                        nodes = providers().len,
                        tolerance = 0): Future[PurchaseId] {.async.} =

      # let cid = client.upload(byteutils.toHex(data)).get
      let expiry = (await ethProvider.currentTime()) + expiry.u256

      # avoid timing issues by filling the slot at the start of the next period
      await advanceToNextPeriod()

      let id = client.requestStorage(
        cid,
        expiry=expiry,
        duration=duration.u256,
        proofProbability=proofProbability.u256,
        collateral=100.u256,
        reward=400.u256,
        nodes=nodes.uint,
        tolerance=tolerance.uint
      ).get

      return id

    setup:
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await mp.config(marketplace)
      period = config.proofs.period.truncate(uint64)
      periodicity = Periodicity(seconds: period.u256)



      discard await ethProvider.send("evm_setIntervalMining", @[%1000])



      # Our Hardhat configuration does use automine, which means that time tracked by `provider.currentTime()` is not
      # advanced until blocks are mined and that happens only when transaction is submitted.
      # As we use in tests provider.currentTime() which uses block timestamp this can lead to synchronization issues.
      await ethProvider.advanceTime(1.u256)

    body