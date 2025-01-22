## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push:
  {.upraises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../clock
import ../blocktype
import ../merkletree
import ../utils

export blocktype

type
  BlockNotFoundError* = object of CodexError

  BlockType* {.pure.} = enum
    Manifest
    Block
    Both

  CidCallback* = proc(cid: Cid): Future[void] {.gcsafe, raises: [].}
  BlockStore* = ref object of RootObj
    onBlockStored*: ?CidCallback

method getBlock*(self: BlockStore, cid: Cid): Future[?!Block] {.base, gcsafe.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("getBlock by cid not implemented!")

method getBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!Block] {.base, gcsafe.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("getBlock by treecid not implemented!")

method getCid*(self: BlockStore, treeCid: Cid, index: Natural): Future[?!Cid] {.base.} =
  ## Get a cid given a tree and index
  ##
  raiseAssert("getCid by treecid not implemented!")

method getBlock*(
    self: BlockStore, address: BlockAddress
): Future[?!Block] {.base, gcsafe.} =
  ## Get a block from the blockstore
  ##

  raiseAssert("getBlock by addr not implemented!")

method getBlockAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Block, CodexProof)] {.base, gcsafe.} =
  ## Get a block and associated inclusion proof by Cid of a merkle tree and an index of a leaf in a tree
  ##

  raiseAssert("getBlockAndProof not implemented!")

method putBlock*(
    self: BlockStore, blk: Block, ttl = Duration.none
): Future[?!void] {.base, gcsafe.} =
  ## Put a block to the blockstore
  ##

  raiseAssert("putBlock not implemented!")

method putCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural, blockCid: Cid, proof: CodexProof
): Future[?!void] {.base, gcsafe.} =
  ## Put a block proof to the blockstore
  ##

  raiseAssert("putCidAndProof not implemented!")

method getCidAndProof*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!(Cid, CodexProof)] {.base, gcsafe.} =
  ## Get a block proof from the blockstore
  ##

  raiseAssert("getCidAndProof not implemented!")

method ensureExpiry*(
    self: BlockStore, cid: Cid, expiry: SecondsSince1970
): Future[?!void] {.base, gcsafe.} =
  ## Ensure that block's assosicated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  raiseAssert("Not implemented!")

method ensureExpiry*(
    self: BlockStore, treeCid: Cid, index: Natural, expiry: SecondsSince1970
): Future[?!void] {.base, gcsafe.} =
  ## Ensure that block's associated expiry is at least given timestamp
  ## If the current expiry is lower then it is updated to the given one, otherwise it is left intact
  ##

  raiseAssert("Not implemented!")

method delBlock*(self: BlockStore, cid: Cid): Future[?!void] {.base, gcsafe.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("delBlock not implemented!")

method delBlock*(
    self: BlockStore, treeCid: Cid, index: Natural
): Future[?!void] {.base, gcsafe.} =
  ## Delete a block from the blockstore
  ##

  raiseAssert("delBlock not implemented!")

method hasBlock*(self: BlockStore, cid: Cid): Future[?!bool] {.base, gcsafe.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("hasBlock not implemented!")

method hasBlock*(
    self: BlockStore, tree: Cid, index: Natural
): Future[?!bool] {.base, gcsafe.} =
  ## Check if the block exists in the blockstore
  ##

  raiseAssert("hasBlock not implemented!")

method listBlocks*(
    self: BlockStore, blockType = BlockType.Manifest
): Future[?!AsyncIter[?Cid]] {.base, gcsafe.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  raiseAssert("listBlocks not implemented!")

method close*(self: BlockStore): Future[void] {.base, gcsafe.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  raiseAssert("close not implemented!")

proc contains*(self: BlockStore, blk: Cid): Future[bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false

proc contains*(self: BlockStore, address: BlockAddress): Future[bool] {.async.} =
  return
    if address.leaf:
      (await self.hasBlock(address.treeCid, address.index)) |? false
    else:
      (await self.hasBlock(address.cid)) |? false
