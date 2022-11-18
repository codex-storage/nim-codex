## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os

import pkg/upraises

push: {.upraises: [].}

import pkg/chronos
import pkg/chronicles
import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import ./blockstore
import ../blocktype
import ../namespaces
import ../manifest

export blocktype, libp2p

const
  CacheBytesKey* = Key.init(CodexMetaNamespace / "quota" / "cache").tryGet
  CachePersistentKey* = Key.init(CodexMetaNamespace / "quota" / "persistent").tryGet

  CodexMetaKey* = Key.init(CodexMetaNamespace).tryGet
  CodexRepoKey* = Key.init(CodexRepoNamespace).tryGet
  CodexBlocksKey* = Key.init(CodexBlocksNamespace).tryGet
  CodexManifestKey* = Key.init(CodexManifestNamespace).tryGet

type
  RepoStore* = ref object of BlockStore
    postFixLen*: int
    ds*: Datastore
    cacheBytes*: uint
    persistBytes*: uint

func makePrefixKey*(self: RepoStore, cid: Cid): ?!Key =
  let
    cidKey = ? Key.init(($cid)[^self.postFixLen..^1] / $cid)

  if ? cid.isManifest:
    success CodexManifestKey / cidKey
  else:
    success CodexBlocksKey / cidKey

method getBlock*(self: RepoStore, cid: Cid): Future[?!Block] {.async.} =
  ## Get a block from the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  without data =? await self.ds.get(key), err:
    trace "Error getting key from datastore", err = err.msg, key
    return failure(newException(BlockNotFoundError, err.msg))

  trace "Got block for cid", cid
  return Block.new(cid, data)

method putBlock*(self: RepoStore, blk: Block): Future[?!void] {.async.} =
  ## Put a block to the blockstore
  ##

  without key =? self.makePrefixKey(blk.cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  trace "Storing block with key", key
  return await self.ds.put(key, blk.data)

method delBlock*(self: RepoStore, cid: Cid): Future[?!void] {.async.} =
  ## Delete a block from the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.ds.delete(key)

method hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err)

  return await self.ds.contains(key)

method listBlocks*(
  self: RepoStore,
  blockType = BlockType.Manifest): Future[?!BlocksIter] {.async.} =
  ## Get the list of blocks in the RepoStore.
  ## This is an intensive operation
  ##

  var
    iter = BlocksIter()

  let key =
    case blockType:
    of BlockType.Manifest: CodexManifestKey
    of BlockType.Block: CodexBlocksKey
    of BlockType.Both: CodexRepoKey

  without queryIter =? (await self.ds.query(Query.init(key))), err:
    trace "Error querying cids in repo", blockType, err = err.msg
    return failure(err)

  proc next(): Future[?Cid] {.async.} =
    await idleAsync()
    iter.finished = queryIter.finished
    if not queryIter.finished:
      if pair =? (await queryIter.next()) and cid =? pair.key:
        trace "Retrieved record from repo", cid
        return Cid.init(cid.value).option

    return Cid.none

  iter.next = next
  return success iter

method close*(self: RepoStore): Future[void] {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  (await self.ds.close()).expect("Should close datastore")

proc hasBlock*(self: RepoStore, cid: Cid): Future[?!bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  without key =? self.makePrefixKey(cid), err:
    trace "Error getting key from provider", err = err.msg
    return failure(err.msg)

  return await self.ds.contains(key)

func new*(
  T: type RepoStore,
  ds: Datastore,
  postFixLen = 2): T =

  T(
    ds: ds,
    postFixLen: postFixLen)
