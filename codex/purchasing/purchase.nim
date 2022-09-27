import ./statemachine
import ./states/pending
import ./purchaseid

# Purchase is implemented as a state machine:
#
#     pending ----> submitted ----------> started
#        \             \    \
#         \             \    -----------> cancelled
#          \             \                   \
#           --------------------------------------> error
#

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
