import pkg/upraises
import ../market
import ../clock
import ../proving
import ./reservations

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onProve*: ?OnProve
    onClear*: ?OnClear
    onSale*: ?OnSale
    proving*: Proving
    reservations*: Reservations

  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  availability: ?Availability): Future[void] {.gcsafe, upraises: [].}
  OnProve* = proc(request: StorageRequest,
                  slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(availability: ?Availability,
                  request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(availability: ?Availability,
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
