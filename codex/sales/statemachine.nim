import std/sequtils
import pkg/chronos
import pkg/questionable
import pkg/upraises
import ../errors
import ../utils/statemachine
import ../market
import ../clock
import ../proving
import ../contracts/requests

export market
export clock
export statemachine
export proving

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
  SalesAgent* = ref object of StateMachineAsync
    sales*: Sales
    requestId*: RequestId
    ask*: StorageAsk
    availability*: ?Availability # TODO: when availability persistence is added, change this to not optional
    request*: ?StorageRequest
    slotIndex*: ?UInt256
    failed*: market.Subscription
    fulfilled*: market.Subscription
    slotFilled*: market.Subscription
    cancelled*: Future[void]
  SaleState* = ref object of AsyncState
  SaleError* = ref object of CodexError
  Availability* = object
    id*: array[32, byte]
    size*: UInt256
    duration*: UInt256
    minPrice*: UInt256
  AvailabilityChange* = proc(availability: Availability) {.gcsafe, upraises: [].}
  # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
  RequestEvent* = proc(state: SaleState, request: StorageRequest): Future[void] {.gcsafe, upraises: [].}
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

method onCancelled*(state: SaleState, request: StorageRequest) {.base, async.} =
  discard

method onFailed*(state: SaleState, request: StorageRequest) {.base, async.} =
  discard

method onSlotFilled*(state: SaleState, requestId: RequestId,
                     slotIndex: UInt256) {.base, async.} =
  discard
