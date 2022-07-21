import std/sequtils
import pkg/codex/market

export market

type
  MockMarket* = ref object of Market
    requested*: seq[StorageRequest]
    fulfilled*: seq[Fulfillment]
    filled*: seq[Slot]
    signer: Address
    subscriptions: Subscriptions
  Fulfillment* = object
    requestId*: array[32, byte]
    proof*: seq[byte]
    host*: Address
  Slot* = object
    requestId*: array[32, byte]
    slotIndex*: UInt256
    proof*: seq[byte]
    host*: Address
  Subscriptions = object
    onRequest: seq[RequestSubscription]
    onFulfillment: seq[FulfillmentSubscription]
    onSlotFilled: seq[SlotFilledSubscription]
  RequestSubscription* = ref object of Subscription
    market: MockMarket
    callback: OnRequest
  FulfillmentSubscription* = ref object of Subscription
    market: MockMarket
    requestId: array[32, byte]
    callback: OnFulfillment
  SlotFilledSubscription* = ref object of Subscription
    market: MockMarket
    requestId: array[32, byte]
    slotIndex: UInt256
    callback: OnSlotFilled

proc new*(_: type MockMarket): MockMarket =
  MockMarket(signer: Address.example)

method getSigner*(market: MockMarket): Future[Address] {.async.} =
  return market.signer

method requestStorage*(market: MockMarket,
                       request: StorageRequest):
                      Future[StorageRequest] {.async.} =
  market.requested.add(request)
  var subscriptions = market.subscriptions.onRequest
  for subscription in subscriptions:
    subscription.callback(request.id, request.ask)
  return request

method getRequest(market: MockMarket,
                  id: array[32, byte]): Future[?StorageRequest] {.async.} =
  for request in market.requested:
    if request.id == id:
      return some request
  return none StorageRequest

method getHost(market: MockMarket,
               id: array[32, byte]): Future[?Address] {.async.} =
  for fulfillment in market.fulfilled:
    if fulfillment.requestId == id:
      return some fulfillment.host
  return none Address

proc fulfillRequest*(market: MockMarket,
                     requestId: array[32, byte],
                     proof: seq[byte],
                     host: Address) =
  let fulfillment = Fulfillment(requestId: requestId, proof: proof, host: host)
  market.fulfilled.add(fulfillment)
  var subscriptions = market.subscriptions.onFulfillment
  for subscription in subscriptions:
    if subscription.requestId == requestId:
      subscription.callback(requestId)

method fulfillRequest*(market: MockMarket,
                       requestId: array[32, byte],
                       proof: seq[byte]) {.async.} =
  market.fulfillRequest(requestid, proof, market.signer)

method getHost(market: MockMarket,
               requestId: array[32, byte],
               slotIndex: UInt256): Future[?Address] {.async.} =
  for slot in market.filled:
    if slot.requestId == requestId and slot.slotIndex == slotIndex:
      return some slot.host
  return none Address

proc emitSlotFilled*(market: MockMarket,
                     requestId: array[32, byte],
                     slotIndex: UInt256) =
  var subscriptions = market.subscriptions.onSlotFilled
  for subscription in subscriptions:
    if subscription.requestId == requestId and
       subscription.slotIndex == slotIndex:
      subscription.callback(requestId, slotIndex)

proc emitRequestFulfilled*(market: MockMarket, requestId: array[32, byte]) =
  var subscriptions = market.subscriptions.onFulfillment
  for subscription in subscriptions:
    if subscription.requestId == requestId:
      subscription.callback(requestId)

proc fillSlot*(market: MockMarket,
               requestId: array[32, byte],
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
                 requestId: array[32, byte],
                 slotIndex: UInt256,
                 proof: seq[byte]) {.async.} =
  market.fillSlot(requestId, slotIndex, proof, market.signer)

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
                             requestId: array[32, byte],
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
                            requestId: array[32, byte],
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

method unsubscribe*(subscription: RequestSubscription) {.async.} =
  subscription.market.subscriptions.onRequest.keepItIf(it != subscription)

method unsubscribe*(subscription: FulfillmentSubscription) {.async.} =
  subscription.market.subscriptions.onFulfillment.keepItIf(it != subscription)

method unsubscribe*(subscription: SlotFilledSubscription) {.async.} =
  subscription.market.subscriptions.onSlotFilled.keepItIf(it != subscription)
