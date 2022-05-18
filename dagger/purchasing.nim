import std/tables
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market
import ./clock

export questionable
export market

type
  Purchasing* = ref object
    market: Market
    clock: Clock
    purchases: Table[array[32, byte], Purchase]
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
    offerExpiryMargin*: UInt256
  Purchase* = ref object
    future: Future[void]
    market: Market
    clock: Clock
    offerExpiryMargin: UInt256
    request*: StorageRequest
    offers*: seq[StorageOffer]
    selected*: ?StorageOffer

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256
const DefaultOfferExpiryMargin = (8 * 60).u256

proc start(purchase: Purchase) {.gcsafe.}
func id*(purchase: Purchase): array[32, byte]

proc new*(_: type Purchasing, market: Market, clock: Clock): Purchasing =
  Purchasing(
    market: market,
    clock: clock,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval,
    offerExpiryMargin: DefaultOfferExpiryMargin
  )

proc populate*(purchasing: Purchasing, request: StorageRequest): StorageRequest =
  result = request
  if result.ask.proofProbability == 0.u256:
    result.ask.proofProbability = purchasing.proofProbability
  if result.expiry == 0.u256:
    result.expiry = (purchasing.clock.now().u256 + purchasing.requestExpiryInterval)
  if result.nonce == array[32, byte].default:
    doAssert randomBytes(result.nonce) == 32

proc purchase*(purchasing: Purchasing, request: StorageRequest): Purchase =
  let request = purchasing.populate(request)
  let purchase = Purchase(
    request: request,
    market: purchasing.market,
    clock: purchasing.clock,
    offerExpiryMargin: purchasing.offerExpiryMargin
  )
  purchase.start()
  purchasing.purchases[purchase.id] = purchase
  purchase

func getPurchase*(purchasing: Purchasing, id: array[32, byte]): ?Purchase =
  if purchasing.purchases.hasKey(id):
    some purchasing.purchases[id]
  else:
    none Purchase

proc selectOffer(purchase: Purchase) {.async.} =
  var cheapest: ?StorageOffer
  for offer in purchase.offers:
    without purchase.clock.now().u256 < offer.expiry - purchase.offerExpiryMargin:
      continue
    without current =? cheapest:
      cheapest = some offer
      continue
    if current.price > offer.price:
      cheapest = some offer
  if cheapest =? cheapest:
    await purchase.market.selectOffer(cheapest.id)

proc run(purchase: Purchase) {.async.} =
  proc onOffer(offer: StorageOffer) =
    purchase.offers.add(offer)
  let market = purchase.market
  purchase.request = await market.requestStorage(purchase.request)
  let subscription = await market.subscribeOffers(purchase.request.id, onOffer)
  await purchase.clock.waitUntil(purchase.request.expiry.truncate(int64))
  await purchase.selectOffer()
  await subscription.unsubscribe()

proc start(purchase: Purchase) =
  purchase.future = purchase.run()

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future

func id*(purchase: Purchase): array[32, byte] =
  purchase.request.id

func finished*(purchase: Purchase): bool =
  purchase.future.finished

func error*(purchase: Purchase): ?(ref CatchableError) =
  if purchase.future.failed:
    some purchase.future.error
  else:
    none (ref CatchableError)
