import std/bitops
import std/sugar

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../contracts/requests
import ../stores/blockstore

proc getTreeCidForSlot*(slot: Slot, blockstore: BlockStore): Future[?!Cid] {.async.} =
  raiseAssert("a")

proc getSlotBlock*(slot: Slot, blockstore: BlockStore, treeCid: Cid, slotBlockIndex: int): Future[?!Block] {.async.} =
  raiseAssert("a")

