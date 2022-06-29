## Nim-Codex
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
  topics = "codex fsstore"

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

  trace "Getting block from filestore", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock.success

  # Try to get this block from the cache
  let cachedBlock = await self.cache.getBlock(cid)
  if cachedBlock.isOK:  # TODO: check for success and non-emptiness
    return cachedBlock

  # Read file contents
  var data: seq[byte]
  let
    path = self.blockPath(cid)
    res = io2.readFile(path, data)

  # TODO: If file doesn't exist - return empty block,
  # other I/O errors are signaled as failures
  if res.isErr:
    if not isFile(path):
      return Block.failure("Couldn't find block in filestore")
    else:
      let error = io2.ioErrorMsg(res.error)
      trace "Cannot read file from filestore", path, error
      return Block.failure("Cannot read file from filestore")

  return Block.new(cid, data)

method putBlock*(
  self: FSStore,
  blk: Block): Future[bool] {.async.} =
  ## Put a block to the blockstore
  ##

  if blk.isEmpty:
    trace "Empty block, ignoring"
    return true

  let path = self.blockPath(blk.cid)
  if isFile(path):
    return true

  # if directory exists it wont fail
  let dir = path.parentDir
  if io2.createPath(dir).isErr:
    trace "Unable to create block prefix dir", dir
    return false

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
  cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  trace "Deleting block from filestore", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let
    path = self.blockPath(cid)
    res = io2.removeFile(path)

  if res.isErr:
    let errmsg = io2.ioErrorMsg(res.error)
    trace "Unable to delete block", path, cid, errmsg
    return errmsg.failure

  return await self.cache.delBlock(cid)

method hasBlock*(self: FSStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking filestore for block existence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return self.blockPath(cid).isFile().success

method listBlocks*(self: FSStore, onBlock: OnBlock) {.async.} =
  debug "Listing all blocks in store"
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

proc new*(
  T: type FSStore,
  repoDir: string,
  postfixLen = 2,
  cache: BlockStore = CacheStore.new()): T =
  T(
    postfixLen: postfixLen,
    repoDir: repoDir,
    cache: cache)
