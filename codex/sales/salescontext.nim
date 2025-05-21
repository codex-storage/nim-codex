import pkg/questionable
import pkg/questionable/results
import pkg/upraises
import pkg/libp2p/cid

import ../market
import ../clock
import ./slotqueue
import ./reservations
import ../blocktype as bt

type
  SalesContext* = ref object
    market*: Market
    clock*: Clock
    # Sales-level callbacks. Closure will be overwritten each time a slot is
    # processed.
    onStore*: ?OnStore
    onClear*: ?OnClear
    onSale*: ?OnSale
    onProve*: ?OnProve
    onExpiryUpdate*: ?OnExpiryUpdate
    reservations*: Reservations
    slotQueue*: SlotQueue
    simulateProofFailures*: int

  BlocksCb* = proc(blocks: seq[bt.Block]): Future[?!void] {.
    gcsafe, async: (raises: [CancelledError])
  .}
  OnStore* = proc(
    request: StorageRequest, slot: uint64, blocksCb: BlocksCb, isRepairing: bool
  ): Future[?!void] {.gcsafe, async: (raises: [CancelledError]).}
  OnProve* = proc(slot: Slot, challenge: ProofChallenge): Future[?!Groth16Proof] {.
    gcsafe, async: (raises: [CancelledError])
  .}
  OnExpiryUpdate* = proc(rootCid: Cid, expiry: SecondsSince1970): Future[?!void] {.
    gcsafe, async: (raises: [CancelledError])
  .}
  OnClear* = proc(request: StorageRequest, slotIndex: uint64) {.gcsafe, raises: [].}
  OnSale* = proc(request: StorageRequest, slotIndex: uint64) {.gcsafe, raises: [].}
