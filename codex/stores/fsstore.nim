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

method getBlock*(self: FSStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the cache or filestore.
  ## Save a copy to the cache if present in the filestore but not in the cache
  ##

  if not self.cache.isNil:
    trace "Getting block from cache or filestore", cid = $cid
  else:
    trace "Getting block from filestore", cid = $cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success cid.emptyBlock

  if not self.cache.isNil:
    let
      cachedBlockRes = await self.cache.getBlock(cid)

    if not cachedBlockRes.isErr:
      return success cachedBlockRes.get
    else:
      trace "Unable to read block from cache", cid = $cid, error = cachedBlockRes.error.msg

  # Read file contents
  var
    data: seq[byte]

  let
    path = self.blockPath(cid)
    res = io2.readFile(path, data)

  if res.isErr:
    if not isFile(path):   # May be, check instead that "res.error == ERROR_FILE_NOT_FOUND" ?
      return failure (ref BlockNotFoundError)(msg: "Block not in filestore")
    else:
      let
        error = io2.ioErrorMsg(res.error)

      trace "Error requesting block from filestore", path, error
      return failure "Error requesting block from filestore: " & error

  without blk =? Block.new(cid, data), error:
    trace "Unable to construct block from data", cid = $cid, error = error.msg
    return failure error

  if not self.cache.isNil:
    let
      putCachedRes = await self.cache.putBlock(blk)

    if putCachedRes.isErr:
      trace "Unable to store block in cache", cid = $cid, error = putCachedRes.error.msg

  return success blk

method putBlock*(self: FSStore, blk: Block): Future[?!void] {.async.} =
  ## Write a block's contents to a file with name based on blk.cid.
  ## Save a copy to the cache
  ##

  if not self.cache.isNil:
    trace "Putting block into filestore and cache", cid = $blk.cid
  else:
    trace "Putting block into filestore", cid = $blk.cid

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
    trace "Unable to store block", path, cid = $blk.cid, error
    return failure("Unable to store block")

  if not self.cache.isNil:
    let
      putCachedRes = await self.cache.putBlock(blk)

    if putCachedRes.isErr:
      trace "Unable to store block in cache", cid = $blk.cid, error = putCachedRes.error.msg

  return success()

method delBlock*(self: FSStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the cache and filestore
  ##

  if not self.cache.isNil:
    trace "Deleting block from cache and filestore", cid = $cid
  else:
    trace "Deleting block from filestore", cid = $cid

  if cid.isEmpty:
    trace "Empty block, ignoring"
    return success()

  if not self.cache.isNil:
    let
      delCachedRes = await self.cache.delBlock(cid)

    if delCachedRes.isErr:
      trace "Unable to delete block from cache", cid = $cid, error = delCachedRes.error.msg

  let
    path = self.blockPath(cid)
    res = io2.removeFile(path)

  if res.isErr:
    let error = io2.ioErrorMsg(res.error)
    trace "Unable to delete block", path, cid = $cid, error
    return error.failure

  return success()

method hasBlock*(self: FSStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if a block exists in the filestore
  ##

  trace "Checking filestore for block existence", cid = $cid
  if cid.isEmpty:
    trace "Empty block, ignoring"
    return true.success

  return self.blockPath(cid).isFile().success

method listBlocks*(self: FSStore, onBlock: OnBlock): Future[?!void] {.async.} =
  ## Process list of all blocks in the filestore via callback.
  ## This is an intensive operation
  ##

  trace "Listing all blocks in filestore"
  for (pkind, folderPath) in self.repoDir.walkDir():
    if pkind != pcDir: continue
    if len(folderPath.basename) != self.postfixLen: continue

    for (fkind, filename) in folderPath.walkDir(relative = true):
      if fkind != pcFile: continue
      let cid = Cid.init(filename)
      if cid.isOk: await onBlock(cid.get())

  return success()

method close*(self: FSStore): Future[void] {.async.} =
  ## Close the underlying cache
  ##

  if not self.cache.isNil: await self.cache.close

proc new*(
  T: type FSStore,
  repoDir: string,
  postfixLen = 2,
  cache: BlockStore = CacheStore.new()): T =
  T(
    postfixLen: postfixLen,
    repoDir: repoDir,
    cache: cache)
