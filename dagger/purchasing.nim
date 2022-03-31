import std/times
import pkg/stint
import pkg/chronos
import pkg/questionable
import pkg/nimcrypto
import ./market

export questionable
export market

type
  Purchasing* = ref object
    market: Market
    proofProbability*: UInt256
    requestExpiryInterval*: UInt256
    offerExpiryMargin*: UInt256
  Purchase* = ref object
    future: Future[void]
    market: Market
    offerExpiryMargin: UInt256
    request*: StorageRequest
    offers*: seq[StorageOffer]
    selected*: ?StorageOffer

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256
const DefaultOfferExpiryMargin = (8 * 60).u256

proc start(purchase: Purchase) {.gcsafe.}

proc new*(_: type Purchasing, market: Market): Purchasing =
  Purchasing(
    market: market,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval,
    offerExpiryMargin: DefaultOfferExpiryMargin
  )

proc populate*(purchasing: Purchasing, request: StorageRequest): StorageRequest =
  result = request
  if result.proofProbability == 0.u256:
    result.proofProbability = purchasing.proofProbability
  if result.expiry == 0.u256:
    result.expiry = (getTime().toUnix().u256 + purchasing.requestExpiryInterval)
  if result.nonce == array[32, byte].default:
    doAssert randomBytes(result.nonce) == 32

proc purchase*(purchasing: Purchasing, request: StorageRequest): Purchase =
  let request = purchasing.populate(request)
  let purchase = Purchase(
    request: request,
    market: purchasing.market,
    offerExpiryMargin: purchasing.offerExpiryMargin
  )
  purchase.start()
  purchase

proc selectOffer(purchase: Purchase) {.async.} =
  var cheapest: ?StorageOffer
  for offer in purchase.offers:
    without getTime().toUnix().u256 < offer.expiry - purchase.offerExpiryMargin:
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
  await market.waitUntil(purchase.request.expiry)
  await purchase.selectOffer()
  await subscription.unsubscribe()

proc start(purchase: Purchase) =
  purchase.future = purchase.run()
  asyncSpawn purchase.future

proc wait*(purchase: Purchase) {.async.} =
  await purchase.future
