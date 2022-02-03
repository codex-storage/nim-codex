
{.push raises: [Defect].}

import chronicles
import chronos

import pkg/dagger/stores
import pkg/questionable
import pkg/questionable/results

logScope:
  topics = "blockstore test mock"

type
  GetBlockMock* = proc(self: BlockStoreMock, cid: Cid): Future[?!Block] {.gcsafe.}
  PutBlockMock* = proc(self: BlockStoreMock, blk: Block): Future[bool] {.gcsafe.}
  DelBlockMock* = proc(self: BlockStoreMock, cid: Cid): Future[bool] {.gcsafe.}
  HasBlockMock* = proc(self: BlockStoreMock, cid: Cid): bool

  BlockStoreMock* = ref object of BlockStore
    getBlock*: GetBlockMock
    putBlock*: PutBlockMock
    delBlock*: DelBlockMock
    hasBlock*: HasBlockMock

method getBlock*(
  self: BlockStoreMock,
  cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##
  if self.getBlock.isNil:
    return await procCall BlockStore(self).getBlock(cid)

  return await self.getBlock(self, cid)

method hasBlock*(
    self: BlockStoreMock,
    cid: Cid): bool {.raises: [Defect, AssertionError].} =
  ## check if the block exists
  ##
  if self.hasBlock.isNil:
    return procCall BlockStore(self).hasBlock(cid)

  return self.hasBlock(self, cid)

method putBlock*(
    self: BlockStoreMock,
    blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##
  if self.putBlock.isNil:
    return await procCall BlockStore(self).putBlock(blk)

  return await self.putBlock(self, blk)

method delBlock*(
    self: BlockStoreMock,
    cid: Cid): Future[bool] {.async.} =
  ## delete a block/s from the block store
  ##
  if self.delBlock.isNil:
    return await procCall BlockStore(self).delBlock(cid)

  return await self.delBlock(self, cid)

func new*(_: type BlockStoreMock,
      getBlock: GetBlockMock = nil,
      putBlock: PutBlockMock = nil,
      delBlock: DelBlockMock = nil,
      hasBlock: HasBlockMock = nil,
    ): BlockStoreMock =

  return BlockStoreMock(
    getBlock: getBlock,
    putBlock: putBlock,
    delBlock: delBlock,
    hasBlock: hasBlock
  )


