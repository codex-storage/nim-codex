import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../node/batch
import ../market
import ../clock
import ../proving
import ./slotqueue
import ./reservations

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onCleanUp*: OnCleanUp
    proving*: Proving
    reservations*: Reservations
    slotQueue*: SlotQueue

  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  onBatch: BatchProc): Future[?!void] {.gcsafe, upraises: [].}
  OnProve* = proc(request: StorageRequest,
                  slot: UInt256): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnCleanUp* = proc: Future[void] {.gcsafe, upraises: [].}
