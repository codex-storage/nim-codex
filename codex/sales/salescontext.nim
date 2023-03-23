import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../blocktype as bt
import ../market
import ../clock
import ../proving
import ./reservations

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    proving*: Proving
    reservations*: Reservations
  # TODO: do not declare BatchProc as it's declared in node, but causes a
  # circular dep if node is imported
  BatchProc* = proc(blocks: seq[bt.Block]): Future[void] {.gcsafe, upraises:[].}

  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  availability: ?Availability,
                  onBatch: BatchProc): Future[?!void] {.gcsafe, upraises: [].}
  OnProve* = proc(request: StorageRequest,
                  slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(availability: ?Availability,
                  request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(availability: ?Availability,
                 request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
