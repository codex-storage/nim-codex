import std/sequtils
import pkg/chronos
import pkg/questionable
import pkg/upraises
import ./reservations
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
    reservations*: Reservations
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
    slotIndex*: UInt256
    failed*: market.Subscription
    fulfilled*: market.Subscription
    slotFilled*: market.Subscription
    cancelled*: Future[void]
  SaleState* = ref object of AsyncState
  SaleError* = ref object of CodexError

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

func findAvailability*(sales: Sales, ask: StorageAsk): ?Availability =
  # TODO: query reservations and get matches
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
