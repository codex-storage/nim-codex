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
  CacheBytesKey* = CodexMetaNamespace / "bytes" / "cache"
  CachePersistentKey* = CodexMetaNamespace / "bytes" / "persistent"

type
  LocalStore* = ref object of BlockStore
    ds*: Datastore
    blocksRepo*: BlockStore # TODO: Should be a Datastore
    manifestRepo*: BlockStore # TODO: Should be a Datastore
    cacheBytes*: uint
    persistBytes*: uint

method getBlock*(self: LocalStore, cid: Cid): Future[?!Block] =
  ## Get a block from the blockstore
  ##

  if cid.isManifest:
    self.manifestRepo.getBlock(cid)
  else:
    self.blocksRepo.getBlock(cid)

method putBlock*(self: LocalStore, blk: Block): Future[?!void] =
  ## Put a block to the blockstore
  ##

  if blk.cid.isManifest:
    self.manifestRepo.putBlock(blk)
  else:
    self.blocksRepo.putBlock(blk)

method delBlock*(self: LocalStore, cid: Cid): Future[?!void] =
  ## Delete a block from the blockstore
  ##

  if cid.isManifest:
    self.manifestRepo.delBlock(cid)
  else:
    self.blocksRepo.delBlock(cid)

method hasBlock*(self: LocalStore, cid: Cid): Future[?!bool] =
  ## Check if the block exists in the blockstore
  ##

  if cid.isManifest:
    self.manifestRepo.hasBlock(cid)
  else:
    self.blocksRepo.hasBlock(cid)

method listBlocks*(
  self: LocalStore,
  blkType: MultiCodec,
  batch = 100,
  onBlock: OnBlock): Future[?!void] =
  ## Get the list of blocks in the LocalStore.
  ## This is an intensive operation
  ##

  if $blkType in ManifestContainers:
    self.manifestRepo.listBlocks(blkType, batch, onBlock)
  else:
    self.blocksRepo.listBlocks(onBlock)

method close*(self: LocalStore) {.async.} =
  ## Close the blockstore, cleaning up resources managed by it.
  ## For some implementations this may be a no-op
  ##

  await self.manifestRepo.close()
  await self.blocksRepo.close()

proc contains*(self: LocalStore, blk: Cid): Future[bool] {.async.} =
  ## Check if the block exists in the blockstore.
  ## Return false if error encountered
  ##

  return (await self.hasBlock(blk)) |? false

func new*(
  T: type LocalStore,
  datastore: Datastore,
  blocksRepo: BlockStore,
  manifestRepo: BlockStore,
  cacheBytes: uint,
  persistBytes: uint): T =
  T(
    datastore: datastore,
    blocksRepo: blocksRepo,
    manifestRepo: manifestRepo,
    cacheBytes: cacheBytes,
    persistBytes: persistBytes)
