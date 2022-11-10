import std/sequtils
import std/tables
import std/hashes
import pkg/codex/market

export market
export tables

type
  MockMarket* = ref object of Market
    activeRequests*: Table[Address, seq[RequestId]]
    activeSlots*: Table[Address, seq[SlotId]]
    requested*: seq[StorageRequest]
    requestEnds*: Table[RequestId, SecondsSince1970]
    state*: Table[RequestId, RequestState]
    fulfilled*: seq[Fulfillment]
    filled*: seq[Slot]
    withdrawn*: seq[RequestId]
    signer: Address
    subscriptions: Subscriptions
  Fulfillment* = object
    requestId*: RequestId
    proof*: seq[byte]
    host*: Address
  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onFulfillment: seq[FulfillmentSubscription]
    onSlotFilled: seq[SlotFilledSubscription]
    onRequestCancelled: seq[RequestCancelledSubscription]
    onRequestFailed: seq[RequestFailedSubscription]
  RequestSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnRequest
  FulfillmentSubscription* = ref object of Subscription
    market: MockMarket
    requestId: RequestId
    callback: OnFulfillment
  SlotFilledSubscription* = ref object of Subscription
    market: MockMarket
    requestId: RequestId
    slotIndex: UInt256
    callback: OnSlotFilled
  RequestCancelledSubscription* = ref object of Subscription
    market: MockMarket
    requestId: RequestId
    callback: OnRequestCancelled
  RequestFailedSubscription* = ref object of Subscription
    market: MockMarket
    requestId: RequestId
    callback: OnRequestCancelled

proc hash*(address: Address): Hash =
  hash(address.toArray)

proc hash*(requestId: RequestId): Hash =
  hash(requestId.toArray)

proc new*(_: type MockMarket): MockMarket =
  MockMarket(signer: Address.example)

method getSigner*(market: MockMarket): Future[Address] {.async.} =
  return market.signer

method requestStorage*(market: MockMarket, request: StorageRequest) {.async.} =
  market.requested.add(request)
  var subscriptions = market.subscriptions.onRequest
  for subscription in subscriptions:
    await subscription.callback(request.id, request.ask)

method myRequests*(market: MockMarket): Future[seq[RequestId]] {.async.} =
  return market.activeRequests[market.signer]

method mySlots*(market: MockMarket): Future[seq[SlotId]] {.async.} =
  return market.activeSlots[market.signer]

method getRequest(market: MockMarket,
                  id: RequestId): Future[?StorageRequest] {.async.} =
  for request in market.requested:
    if request.id == id:
      return some request
  return none StorageRequest

method getState*(market: MockMarket,
                 requestId: RequestId): Future[?RequestState] {.async.} =
  return market.state.?[requestId]

method getRequestEnd*(market: MockMarket,
                      id: RequestId): Future[SecondsSince1970] {.async.} =
  return market.requestEnds[id]

method getHost*(market: MockMarket,
               requestId: RequestId,
               slotIndex: UInt256): Future[?Address] {.async.} =
  for slot in market.filled:
    if slot.requestId == requestId and slot.slotIndex == slotIndex:
      return some slot.host
  return none Address

proc emitSlotFilled*(market: MockMarket,
                     requestId: RequestId,
                     slotIndex: UInt256) =
  var subscriptions = market.subscriptions.onSlotFilled
  for subscription in subscriptions:
    if subscription.requestId == requestId and
       subscription.slotIndex == slotIndex:
      asyncSpawn subscription.callback(requestId, slotIndex)

proc emitRequestCancelled*(market: MockMarket,
                     requestId: RequestId) =
  var subscriptions = market.subscriptions.onRequestCancelled
  for subscription in subscriptions:
    if subscription.requestId == requestId:
      asyncSpawn subscription.callback(requestId)

proc emitRequestFulfilled*(market: MockMarket, requestId: RequestId) =
  var subscriptions = market.subscriptions.onFulfillment
  for subscription in subscriptions:
    if subscription.requestId == requestId:
      asyncSpawn subscription.callback(requestId)

proc emitRequestFailed*(market: MockMarket, requestId: RequestId) =
  var subscriptions = market.subscriptions.onRequestFailed
  for subscription in subscriptions:
    if subscription.requestId == requestId:
      asyncSpawn subscription.callback(requestId)

proc fillSlot*(market: MockMarket,
               requestId: RequestId,
               slotIndex: UInt256,
               proof: seq[byte],
               host: Address) =
  let slot = Slot(
    requestId: requestId,
    slotIndex: slotIndex,
    proof: proof,
    host: host
  )
  market.filled.add(slot)
  market.emitSlotFilled(requestId, slotIndex)

method fillSlot*(market: MockMarket,
                 requestId: RequestId,
                 slotIndex: UInt256,
                 proof: seq[byte]) {.async.} =
  market.fillSlot(requestId, slotIndex, proof, market.signer)

method withdrawFunds*(market: MockMarket,
                      requestId: RequestId) {.async.} =
  market.withdrawn.add(requestId)
  market.emitRequestCancelled(requestId)

method subscribeRequests*(market: MockMarket,
                          callback: OnRequest):
                         Future[Subscription] {.async.} =
  let subscription = RequestSubscription(
    market: market,
    callback: callback
  )
  market.subscriptions.onRequest.add(subscription)
  return subscription

method subscribeFulfillment*(market: MockMarket,
                             requestId: RequestId,
                             callback: OnFulfillment):
                            Future[Subscription] {.async.} =
  let subscription = FulfillmentSubscription(
    market: market,
    requestId: requestId,
    callback: callback
  )
  market.subscriptions.onFulfillment.add(subscription)
  return subscription

method subscribeSlotFilled*(market: MockMarket,
                            requestId: RequestId,
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[Subscription] {.async.} =
  let subscription = SlotFilledSubscription(
    market: market,
    requestId: requestId,
    slotIndex: slotIndex,
    callback: callback
  )
  market.subscriptions.onSlotFilled.add(subscription)
  return subscription

method subscribeRequestCancelled*(market: MockMarket,
                            requestId: RequestId,
                            callback: OnRequestCancelled):
                           Future[Subscription] {.async.} =
  let subscription = RequestCancelledSubscription(
    market: market,
    requestId: requestId,
    callback: callback
  )
  market.subscriptions.onRequestCancelled.add(subscription)
  return subscription

method subscribeRequestFailed*(market: MockMarket,
                               requestId: RequestId,
                               callback: OnRequestFailed):
                             Future[Subscription] {.async.} =
  let subscription = RequestFailedSubscription(
    market: market,
    requestId: requestId,
    callback: callback
  )
  market.subscriptions.onRequestFailed.add(subscription)
  return subscription

method unsubscribe*(subscription: RequestSubscription) {.async.} =
  subscription.market.subscriptions.onRequest.keepItIf(it != subscription)

method unsubscribe*(subscription: FulfillmentSubscription) {.async.} =
  subscription.market.subscriptions.onFulfillment.keepItIf(it != subscription)

method unsubscribe*(subscription: SlotFilledSubscription) {.async.} =
  subscription.market.subscriptions.onSlotFilled.keepItIf(it != subscription)

method unsubscribe*(subscription: RequestCancelledSubscription) {.async.} =
  subscription.market.subscriptions.onRequestCancelled.keepItIf(it != subscription)

method unsubscribe*(subscription: RequestFailedSubscription) {.async.} =
  subscription.market.subscriptions.onRequestFailed.keepItIf(it != subscription)
