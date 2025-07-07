import macros
import std/unittest

import pkg/chronos
import pkg/ethers/erc20
from pkg/libp2p import Cid
import pkg/codex/contracts/marketplace as mp
import pkg/codex/periods
import pkg/codex/utils/json
from pkg/codex/utils import roundUp, divUp
import ./multinodes except Subscription, Event
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
    var subscriptions: seq[Subscription] = @[]
    var tokenSubscription: Subscription

    proc check(cond: bool, reason = "Check failed"): void =
      if not cond:
        fail(reason)

    proc marketplaceSubscribe[E: Event](
        event: type E, handler: EventHandler[E]
    ) {.async.} =
      let sub = await marketplace.subscribe(event, handler)
      subscriptions.add(sub)

    proc tokenSubscribe(
        handler: proc(event: ?!Transfer) {.gcsafe, raises: [].}
    ) {.async.} =
      let sub = await token.subscribe(Transfer, handler)
      tokenSubscription = sub

    proc subscribeOnRequestFulfilled(
        requestId: RequestId
    ): Future[AsyncEvent] {.async.} =
      let event = newAsyncEvent()

      proc onRequestFulfilled(eventResult: ?!RequestFulfilled) {.raises: [].} =
        assert not eventResult.isErr
        let er = !eventResult

        if er.requestId == requestId:
          event.fire()

      let sub = await marketplace.subscribe(RequestFulfilled, onRequestFulfilled)
      subscriptions.add(sub)

      return event

    proc getCurrentPeriod(): Future[Period] {.async.} =
      return periodicity.periodOf((await ethProvider.currentTime()).truncate(uint64))

    proc waitForRequestToStart(
        requestId: RequestId, seconds = 10 * 60 + 10
    ): Future[void] {.async.} =
      let event = newAsyncEvent()

      proc onRequestFulfilled(eventResult: ?!RequestFulfilled) {.raises: [].} =
        assert not eventResult.isErr
        let er = !eventResult

        if er.requestId == requestId:
          event.fire()

      let sub = await marketplace.subscribe(RequestFulfilled, onRequestFulfilled)
      subscriptions.add(sub)

      await event.wait().wait(timeout = chronos.seconds(seconds))

    proc getSecondsTillRequestEnd(requestId: RequestId): Future[int64] {.async.} =
      let currentTime = await ethProvider.currentTime()
      let requestEnd = await marketplace.requestEnd(requestId)
      return requestEnd.int64 - currentTime.truncate(int64)

    proc waitForRequestToFail(
        requestId: RequestId, seconds = (5 * 60) + 10
    ): Future[void] {.async.} =
      let event = newAsyncEvent()

      proc onRequestFailed(eventResult: ?!RequestFailed) {.raises: [].} =
        assert not eventResult.isErr
        let er = !eventResult

        if er.requestId == requestId:
          event.fire()

      let sub = await marketplace.subscribe(RequestFailed, onRequestFailed)
      subscriptions.add(sub)

      await event.wait().wait(timeout = chronos.seconds(seconds))

    proc advanceToNextPeriod() {.async.} =
      let periodicity = Periodicity(seconds: period)
      let currentTime = (await ethProvider.currentTime()).truncate(uint64)
      let currentPeriod = periodicity.periodOf(currentTime)
      let endOfPeriod = periodicity.periodEnd(currentPeriod)

      await ethProvider.advanceTimeTo(endOfPeriod.u256 + 1)

    template eventuallyP(condition: untyped, finalPeriod: Period): bool =
      proc eventuallyP(): Future[bool] {.async: (raises: [CancelledError]).} =
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
        duration: uint64 = 20 * 60.uint64,
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

    proc requestStorage(
        client: CodexClient,
        proofProbability = 3.u256,
        duration = 20 * 60.uint64,
        pricePerBytePerSecond = 1.u256,
        collateralPerByte = 1.u256,
        expiry = 10 * 60.uint64,
        nodes = 3,
        tolerance = 1,
        blocks = 8,
        data = seq[byte].none,
    ): Future[(PurchaseId, RequestId)] {.async.} =
      let bytes = data |? await RandomChunker.example(blocks = blocks)
      let cid = (await client.upload(bytes)).get

      let purchaseId = await client.requestStorage(
        cid,
        duration = duration,
        pricePerBytePerSecond = pricePerBytePerSecond,
        proofProbability = proofProbability,
        expiry = expiry,
        collateralPerByte = collateralPerByte,
        nodes = nodes,
        tolerance = tolerance,
      )

      let requestId = (await client.requestId(purchaseId)).get

      return (purchaseId, requestId)

    setup:
      marketplace = Marketplace.new(Marketplace.address, ethProvider.getSigner())
      let tokenAddress = await marketplace.token()
      token = Erc20Token.new(tokenAddress, ethProvider.getSigner())
      let config = await marketplace.configuration()
      period = config.proofs.period
      periodicity = Periodicity(seconds: period)
      subscriptions = @[]
    teardown:
      for subscription in subscriptions:
        await subscription.unsubscribe()

      if not tokenSubscription.isNil:
        await tokenSubscription.unsubscribe()

    body
