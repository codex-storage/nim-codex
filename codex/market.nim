import pkg/chronos
import pkg/upraises
import pkg/questionable
import ./contracts/requests

export chronos
export questionable
export requests

type
  Market* = ref object of RootObj
  Subscription* = ref object of RootObj
  OnRequest* = proc(id: RequestId, ask: StorageAsk) {.gcsafe, upraises:[].}
  OnFulfillment* = proc(requestId: RequestId) {.gcsafe, upraises: [].}
  OnSlotFilled* = proc(requestId: RequestId, slotIndex: UInt256) {.gcsafe, upraises:[].}
  OnRequestCancelled* = proc(requestId: RequestId) {.gcsafe, upraises:[].}

method getSigner*(market: Market): Future[Address] {.base, async.} =
  raiseAssert("not implemented")

method requestStorage*(market: Market,
                       request: StorageRequest):
                      Future[StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method myRequests*(market: Market): Future[seq[RequestId]] {.base, async.} =
  raiseAssert("not implemented")

method getRequest*(market: Market,
                   id: RequestId):
                  Future[?StorageRequest] {.base, async.} =
  raiseAssert("not implemented")

method getState*(market: Market,
                 requestId: RequestId): Future[?RequestState] {.base, async.} =
  raiseAssert("not implemented")

method getHost*(market: Market,
                requestId: RequestId,
                slotIndex: UInt256): Future[?Address] {.base, async.} =
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

method unsubscribe*(subscription: Subscription) {.base, async, upraises:[].} =
  raiseAssert("not implemented")
