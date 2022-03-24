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
  Purchase* = ref object

const DefaultProofProbability = 100.u256
const DefaultRequestExpiryInterval = (10 * 60).u256

proc new*(_: type Purchasing, market: Market): Purchasing =
  Purchasing(
    market: market,
    proofProbability: DefaultProofProbability,
    requestExpiryInterval: DefaultRequestExpiryInterval
  )

proc purchase*(purchasing: Purchasing, request: StorageRequest): Purchase =
  var request = request
  if request.proofProbability == 0.u256:
    request.proofProbability = purchasing.proofProbability
  if request.expiry == 0.u256:
    request.expiry = (getTime().toUnix().u256 + purchasing.requestExpiryInterval)
  if request.nonce == array[32, byte].default:
    doAssert randomBytes(request.nonce) == 32
  asyncSpawn purchasing.market.requestStorage(request)

proc wait*(purchase: Purchase) {.async.} =
  discard
