import ./statemachine
import ./states/pending
import ./states/unknown
import ./purchaseid

# Purchase is implemented as a state machine.
#
# It can either be a new (pending) purchase that still needs to be submitted
# on-chain, or it is a purchase that was previously submitted on-chain, and
# we're just restoring its (unknown) state after a node restart.
#
#                                                                      |
#                                                                      v
#                                         ------------------------- unknown
#        |                               /                             /
#        v                              v                             /
#     pending ----> submitted ----> started ---------> finished <----/
#                        \              \                           /
#                         \              ------------> failed <----/
#                          \                                      /
#                           --> cancelled <-----------------------

export Purchase
export purchaseid

func newPurchase*(request: StorageRequest,
                  market: Market,
                  clock: Clock): Purchase =
  Purchase(
    future: Future[void].new(),
    request: request,
    market: market,
    clock: clock
  )

proc start*(purchase: Purchase) =
  purchase.switch(PurchasePending())

proc load*(purchase: Purchase) =
  purchase.switch(PurchaseUnknown())

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): PurchaseId =
  PurchaseId(purchase.request.id)

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
