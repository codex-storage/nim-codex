import std/bitops
import std/sugar

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../contracts/requests
import ../stores/blockstore
import ../manifest

proc getTreeCidForSlot*(slot: Slot, blockstore: BlockStore): Future[?!Cid] {.async.} =
  without manifestBlockCid =? Cid.init(slot.request.content.cid).mapFailure, err:
    error "Unable to init CID from slot.content.cid"
    return failure err

  without manifestBlock =? await blockstore.getBlock(manifestBlockCid), err:
    error "Failed to fetch manifest block", cid = manifestBlockCid
    return failure err

  without manifest =? Manifest.decode(manifestBlock):
    error "Unable to decode manifest"
    return failure("Unable to decode manifest")

  return success(manifest.treeCid)

proc getSlotBlock*(slot: Slot, blockstore: BlockStore, treeCid: Cid, slotBlockIndex: int): Future[?!Block] {.async.} =
  raiseAssert("a")

