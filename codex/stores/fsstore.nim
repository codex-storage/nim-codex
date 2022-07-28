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

method getBlock*(self: FSStore, cid: Cid): Future[?! (? Block)] {.async.} =
  ## Get a block from the stores
  ##

  trace "Getting block from filestore", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return cid.emptyBlock.some.success

  let cachedBlock = await self.cache.getBlock(cid)
  if cachedBlock.isErr:
    return cachedBlock
  if cachedBlock.get.isSome:
    trace "Retrieved block from cache", cid
    return cachedBlock

  # Read file contents
  var data: seq[byte]
  let
    path = self.blockPath(cid)
    res = io2.readFile(path, data)

  if res.isErr:
    if not isFile(path):   # May be, check instead that "res.error == ERROR_FILE_NOT_FOUND" ?
      return Block.none.success
    else:
      let error = io2.ioErrorMsg(res.error)
      trace "Cannot read file from filestore", path, error
      return failure("Cannot read file from filestore")

  without var blk =? Block.new(cid, data), error:
    return error.failure

  # TODO: add block to the cache
  return blk.some.success

method putBlock*(self: FSStore, blk: Block): Future[?!void] {.async.} =
  ## Write block contents to file with name based on blk.cid,
  ## save second copy to the cache
  ##

  if blk.isEmpty:
    trace "Empty block, ignoring"
    return success()

  let path = self.blockPath(blk.cid)
  if isFile(path):
    return success()

  # If directory exists createPath wont fail
  let dir = path.parentDir
  if io2.createPath(dir).isErr:
    trace "Unable to create block prefix dir", dir
    return failure("Unable to create block prefix dir")

  let res = io2.writeFile(path, blk.data)
  if res.isErr:
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to store block", path, cid = blk.cid, error
    return failure("Unable to store block")

  if isErr (await self.cache.putBlock(blk)):
    trace "Unable to store block in cache", cid = blk.cid

  return success()

method delBlock*(self: FSStore, cid: Cid): Future[?!void] {.async.} =
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
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to delete block", path, cid, error
    return error.failure

  return await self.cache.delBlock(cid)

method hasBlock*(self: FSStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  trace "Checking filestore for block existence", cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return self.blockPath(cid).isFile().success

method listBlocks*(self: FSStore, onBlock: OnBlock): Future[?!void] {.async.} =
  ## Get the list of blocks in the BlockStore. This is an intensive operation
  ##

  trace "Listing all blocks in filestore"
  for (pkind, folderPath) in self.repoDir.walkDir():
    if pkind != pcDir: continue
    if len(folderPath.basename) != self.postfixLen: continue

    for (fkind, filename) in folderPath.walkDir(relative = true):
      if fkind != pcFile: continue
      let cid = Cid.init(filename)
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

  return success()

proc new*(
  T: type FSStore,
  repoDir: string,
  postfixLen = 2,
  cache: BlockStore = CacheStore.new()): T =
  T(
    postfixLen: postfixLen,
    repoDir: repoDir,
    cache: cache)
