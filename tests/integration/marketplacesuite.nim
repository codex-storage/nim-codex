import pkg/chronos
import pkg/ethers/erc20
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

    proc getCurrentPeriod(): Future[Period] {.async.} =
      return periodicity.periodOf(await ethProvider.currentTime())

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period.u256)
      let currentTime = await ethProvider.currentTime()
      let currentPeriod = periodicity.periodOf(currentTime)
      let endOfPeriod = periodicity.periodEnd(currentPeriod)
      await ethProvider.advanceTimeTo(endOfPeriod + 1)

    template eventuallyP(condition: untyped, finalPeriod: Period): bool =
      proc eventuallyP(): Future[bool] {.async.} =
        while (
          let currentPeriod = await getCurrentPeriod()
          currentPeriod <= finalPeriod
        )
        :
          if condition:
            return true
          await sleepAsync(1.millis)
        return condition

      await eventuallyP()

    proc periods(p: int): uint64 =
      p.uint64 * period

    # Purposely overshooting
    # TODO: find a better way to compute slot size for the given
    # dataset size
    # I found this snippet in tests/integration/testproofs.nim:
    # let datasetSizeInBlocks = 3
    # let data = await RandomChunker.example(blocks=datasetSizeInBlocks)
    # # original data = 3 blocks so slot size will be 4 blocks
    # let slotSize = (DefaultBlockSize * 4.NBytes).Natural.u256
    proc availabilityTotalSizeForDataSize(dataSize: int): UInt256 =
      (dataSize * 2).u256

    proc createAvailabilitiesForData(
        data: string, duration: uint64, minPricePerBytePerSecond: UInt256
    ) =
      let availabilityTotalSize = availabilityTotalSizeForDataSize(data.len)
      let totalCollateral = availabilityTotalSize * minPricePerBytePerSecond
      # post availability to each provider
      for i in 0 ..< providers().len:
        let provider = providers()[i].client

        discard provider.postAvailability(
          totalSize = availabilityTotalSize,
          duration = duration.u256,
          minPricePerBytePerSecond = minPricePerBytePerSecond,
          totalCollateral = totalCollateral,
        )

    proc requestStorage(
        client: CodexClient,
        cid: Cid,
        proofProbability = 1,
        duration: uint64 = 12.periods,
        pricePerBytePerSecond = 1.u256,
        collateralPerByte = 1.u256,
        expiry: uint64 = 4.periods,
        nodes = providers().len,
        tolerance = 0,
    ): Future[PurchaseId] {.async.} =
      let id = client.requestStorage(
        cid,
        expiry = expiry.uint,
        duration = duration.u256,
        proofProbability = proofProbability.u256,
        collateralPerByte = collateralPerByte,
        pricePerBytePerSecond = pricePerBytePerSecond,
        nodes = nodes.uint,
        tolerance = tolerance.uint,
      ).get

      return id

    setup:
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await marketplace.configuration()
      period = config.proofs.period.truncate(uint64)
      periodicity = Periodicity(seconds: period.u256)

    body
