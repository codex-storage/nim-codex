import pkg/upraises
import ../market
import ../clock
import ../proving
import ./availability

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onSaleErrored*: ?OnSaleErrored
    proving*: Proving
  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  availability: ?Availability): Future[void] {.gcsafe, upraises: [].}
  OnClear* = proc(availability: ?Availability,# TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                  request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(availability: ?Availability, # TODO: when availability changes introduced, make availability non-optional (if we need to keep it at all)
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSaleErrored* = proc(availability: Availability) {.gcsafe, upraises: [].}
