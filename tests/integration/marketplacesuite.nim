import pkg/chronos
import pkg/ethers/erc20
from pkg/libp2p import Cid
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import pkg/codex/utils/json
from pkg/codex/utils import roundUp, divUp
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
      return periodicity.periodOf((await ethProvider.currentTime()).truncate(uint64))

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period)
      let currentTime = (await ethProvider.currentTime()).truncate(uint64)
      let currentPeriod = periodicity.periodOf(currentTime)
      let endOfPeriod = periodicity.periodEnd(currentPeriod)
      await ethProvider.advanceTimeTo(endOfPeriod.u256 + 1)

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

    proc slotSize(blocks, nodes, tolerance: int): UInt256 =
      let ecK = nodes - tolerance
      let blocksRounded = roundUp(blocks, ecK)
      let blocksPerSlot = divUp(blocksRounded, ecK)
      (DefaultBlockSize * blocksPerSlot.NBytes).Natural.u256

    proc datasetSize(blocks, nodes, tolerance: int): UInt256 =
      return nodes.u256 * slotSize(blocks, nodes, tolerance)

    proc createAvailabilities(
        datasetSize: uint64,
        duration: uint64,
        collateralPerByte: UInt256,
        minPricePerBytePerSecond: UInt256,
    ): Future[void] {.async: (raises: [CancelledError, HttpError, ConfigurationError]).} =
      let totalCollateral = datasetSize.u256 * collateralPerByte
      # post availability to each provider
      for i in 0 ..< providers().len:
        let provider = providers()[i].client

        discard await provider.postAvailability(
          totalSize = datasetSize,
          duration = duration.uint64,
          minPricePerBytePerSecond = minPricePerBytePerSecond,
          totalCollateral = totalCollateral,
        )

    proc requestStorage(
        client: CodexClient,
        cid: Cid,
        proofProbability = 1.u256,
        duration: uint64 = 12.periods,
        pricePerBytePerSecond = 1.u256,
        collateralPerByte = 1.u256,
        expiry: uint64 = 4.periods,
        nodes = providers().len,
        tolerance = 0,
    ): Future[PurchaseId] {.async: (raises: [CancelledError, HttpError]).} =
      let id = (
        await client.requestStorage(
          cid,
          expiry = expiry,
          duration = duration,
          proofProbability = proofProbability,
          collateralPerByte = collateralPerByte,
          pricePerBytePerSecond = pricePerBytePerSecond,
          nodes = nodes.uint,
          tolerance = tolerance.uint,
        )
      ).get

      return id

    setup:
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await marketplace.configuration()
      period = config.proofs.period
      periodicity = Periodicity(seconds: period)

    body
