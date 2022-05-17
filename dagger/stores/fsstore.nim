## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}

import std/os

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/stew/io2

import ./cachestore
import ./blockstore

export blockstore

logScope:
  topics = "dagger fsstore"

type
  FSStore* = ref object of BlockStore
    cache: BlockStore
    repoDir: string
    postfixLen*: int

template blockPath*(self: FSStore, cid: Cid): string =
  self.repoDir / ($cid)[^self.postfixLen..^1] / $cid

method getBlock*(
  self: FSStore,
  cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the stores
  ##

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock.success

  if cid in self.cache:
    return await self.cache.getBlock(cid)

  if cid notin self:
    return Block.failure("Couldn't find block in fs store")

  var data: seq[byte]
  let path = self.blockPath(cid)
  if (
    let res = io2.readFile(path, data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Cannot read file from fs store", path , error
    return Block.failure("Cannot read file from fs store")

  return Block.new(cid, data)

method putBlock*(
  self: FSStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  if blk.isEmpty:
    trace "Empty block, ignoring"
    return true

  if blk.cid in self:
    return true

  # if directory exists it wont fail
  if io2.createPath(self.blockPath(blk.cid).parentDir).isErr:
    trace "Unable to create block prefix dir", dir = self.blockPath(blk.cid).parentDir
    return false

  let path = self.blockPath(blk.cid)
  if (
    let res = io2.writeFile(path, blk.data);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store block", path, cid = blk.cid, error
    return false

  if not (await self.cache.putBlock(blk)):
    trace "Unable to store block in cache", cid = blk.cid

  return true

method delBlock*(
  self: FSStore,
  cid: Cid): Future[bool] {.async.} =
  ## Delete a block/s from the block store
  ##

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true

  let path = self.blockPath(cid)
  if (
    let res = io2.removeFile(path);
    res.isErr):
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to delete block", path, cid, error
    return false

  if not (await self.cache.delBlock(cid)):
    trace "Unable to delete block from cache", cid

  return true

method hasBlock*(self: FSStore, cid: Cid): bool =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking for block existence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true

  self.blockPath(cid).isFile()

method listBlocks*(self: FSStore, onBlock: OnBlock) {.async.} =
  debug "Finding all blocks in store"
  for (pkind, folderPath) in self.repoDir.walkDir():
    if pkind != pcDir: continue
    let baseName = basename(folderPath)
    if baseName.len != self.postfixLen: continue

    for (fkind, filePath) in folderPath.walkDir(false):
      if fkind != pcFile: continue
      let cid = Cid.init(basename(filePath))
      if cid.isOk:
        # getting a weird `Error: unhandled exception: index 1 not in 0 .. 0 [IndexError]`
        # compilation error if using different syntax/construct bellow
        try:
          await onBlock(cid.get())
        except CancelledError as exc:
          trace "Cancelling list blocks"
          raise exc
        except CatchableError as exc:
          trace "Couldn't get block", cid = $(cid.get())

      # TODO: this should run on a thread which
      # wouldn't need the sleep
      await sleepAsync(100.millis) # avoid blocking

proc new*(
  T: type FSStore,
  repoDir: string,
  postfixLen = 2,
  cache: BlockStore = CacheStore.new()): T =
  T(
    postfixLen: postfixLen,
    repoDir: repoDir,
    cache: cache)
