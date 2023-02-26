import std/sequtils
import pkg/chronos
import pkg/questionable
import pkg/upraises
import ../errors
import ../utils/asyncstatemachine
import ../utils/optionalcast
import ../market
import ../clock
import ../proving
import ../contracts/requests

export market
export clock
export asyncstatemachine
export proving
export optionalcast

type
  Sales* = ref object
    market*: Market
    clock*: Clock
    subscription*: ?market.Subscription
    available: seq[Availability]
    onStore: ?OnStore
    onProve: ?OnProve
    onClear: ?OnClear
    onSale: ?OnSale
    proving*: Proving
    agents*: seq[SalesAgent]
  SalesAgent* = ref object of Machine
    sales*: Sales
    ask*: StorageAsk
    availability*: ?Availability # TODO: when availability persistence is added, change this to not optional
    requestId*: RequestId
    request*: ?StorageRequest
    slotIndex*: UInt256
    subscribeFailed*: market.Subscription
    subscribeFulfilled*: market.Subscription
    subscribeSlotFilled*: market.Subscription
    waitForCancelled*: Future[void]
    restoredFromChain*: bool
    slotState*: TransitionProperty[SlotState]
    requestState*: TransitionProperty[RequestState]
    proof*: TransitionProperty[seq[byte]]
    slotHostIsMe*: TransitionProperty[bool]
    downloaded*: TransitionProperty[bool]
  SaleError* = object of CodexError
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  AvailabilityChange* = proc(availability: Availability) {.gcsafe, upraises: [].}
  # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  availability: ?Availability): Future[void] {.gcsafe, upraises: [].}
  OnProve* = proc(request: StorageRequest,
                  slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(availability: ?Availability,# TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                  request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(availability: ?Availability, # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}

proc `onStore=`*(sales: Sales, onStore: OnStore) =
  sales.onStore = some onStore

proc `onProve=`*(sales: Sales, onProve: OnProve) =
  sales.onProve = some onProve

proc `onClear=`*(sales: Sales, onClear: OnClear) =
  sales.onClear = some onClear

proc `onSale=`*(sales: Sales, callback: OnSale) =
  sales.onSale = some callback

proc onStore*(sales: Sales): ?OnStore = sales.onStore

proc onProve*(sales: Sales): ?OnProve = sales.onProve

proc onClear*(sales: Sales): ?OnClear = sales.onClear

proc onSale*(sales: Sales): ?OnSale = sales.onSale

proc available*(sales: Sales): seq[Availability] = sales.available

func add*(sales: Sales, availability: Availability) =
  if not sales.available.contains(availability):
    sales.available.add(availability)
  # TODO: add to disk (persist), serialise to json.

func remove*(sales: Sales, availability: Availability) =
  sales.available.keepItIf(it != availability)
  # TODO: remove from disk availability, mark as in use by assigning
  # a slotId, so that it can be used for restoration (node restart)

func findAvailability*(sales: Sales, ask: StorageAsk): ?Availability =
  for availability in sales.available:
    if ask.slotSize <= availability.size and
       ask.duration <= availability.duration and
       ask.pricePerSlot >= availability.minPrice:
      return some availability
