import pkg/chronos
import pkg/upraises
import pkg/questionable
import ./contracts/requests
import ./clock

export chronos
export questionable
export requests
export SecondsSince1970

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: RequestId, ask: StorageAsk): Future[void] {.gcsafe, upraises:[].}
  OnFulfillment* = proc(requestId: RequestId): Future[void] {.gcsafe, upraises: [].}
  OnSlotFilled* = proc(requestId: RequestId, slotIndex: UInt256): Future[void] {.gcsafe, upraises:[].}
  OnRequestCancelled* = proc(requestId: RequestId): Future[void] {.gcsafe, upraises:[].}
  OnRequestFailed* = proc(requestId: RequestId): Future[void] {.gcsafe, upraises:[].}

method getSigner*(market: Market): Future[Address] {.base, async.} =
  raiseAssert("not implemented")

method requestStorage*(market: Market,
                       request: StorageRequest) {.base, async.} =
  raiseAssert("not implemented")

method myRequests*(market: Market): Future[seq[RequestId]] {.base, async.} =
  raiseAssert("not implemented")

method mySlots*(market: Market): Future[seq[SlotId]] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(market: Market,
                   id: RequestId):
                  Future[?StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method getState*(market: Market,
                 requestId: RequestId): Future[?RequestState] {.base, async.} =
  raiseAssert("not implemented")

method getRequestEnd*(market: Market,
                      id: RequestId): Future[SecondsSince1970] {.base, async.} =
  raiseAssert("not implemented")

method getHost*(market: Market,
                requestId: RequestId,
                slotIndex: UInt256): Future[?Address] {.base, async.} =
  raiseAssert("not implemented")

method getSlot*(market: Market,
                slotId: SlotId): Future[?Slot] {.base, async.} =
  raiseAssert("not implemented")

method fillSlot*(market: Market,
                 requestId: RequestId,
                 slotIndex: UInt256,
                 proof: seq[byte]) {.base, async.} =
  raiseAssert("not implemented")

method withdrawFunds*(market: Market,
                      requestId: RequestId) {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequests*(market: Market,
                          callback: OnRequest):
                         Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeFulfillment*(market: Market,
                             requestId: RequestId,
                             callback: OnFulfillment):
                            Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeSlotFilled*(market: Market,
                            requestId: RequestId,
                            slotIndex: UInt256,
                            callback: OnSlotFilled):
                           Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestCancelled*(market: Market,
                                  requestId: RequestId,
                                  callback: OnRequestCancelled):
                                Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method subscribeRequestFailed*(market: Market,
                               requestId: RequestId,
                               callback: OnRequestFailed):
                             Future[Subscription] {.base, async.} =
  raiseAssert("not implemented")

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
