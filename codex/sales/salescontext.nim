import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import ../node/batch
import ../market
import ../clock
import ./slotqueue
import ./reservations

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onFilled*: ?OnFilled
    onCleanUp*: OnCleanUp
    onProve*: ?OnProve
    reservations*: Reservations
    slotQueue*: SlotQueue
    simulateProofFailures*: int

  OnStore* = proc(request: StorageRequest,
                  slot: UInt256,
                  onBatch: BatchProc): Future[?!void] {.gcsafe, upraises: [].}
  OnProve* = proc(slot: Slot): Future[seq[byte]] {.gcsafe, upraises: [].}
  OnClear* = proc(request: StorageRequest,
                  slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnSale* = proc(request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}

  # OnFilled has same function as OnSale, but is kept for internal purposes and should not be set by any external
  # purposes as it is used for freeing Queue Workers after slot is filled. And the callbacks allows only
  # one callback to be set, so if some other component would use it, it would override the Slot Queue freeing
  # mechanism which would lead to blocking of the queue.
  OnFilled* = proc(request: StorageRequest,
                 slotIndex: UInt256) {.gcsafe, upraises: [].}
  OnCleanUp* = proc: Future[void] {.gcsafe, upraises: [].}
