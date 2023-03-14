## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/os

import pkg/chronos
import pkg/datastore
import pkg/confutils
import pkg/confutils/defs

import ../namespaces
import ../consts
import ./blockstore
import ./repostore
import ./cachestore
import ./maintenance

type
  BlockStoreManager* = ref object of RootObj
    repoStore: RepoStore
    maintenance: BlockMaintainer
    blockStore: BlockStore
  BlockStoreManagerConfig* = ref object
    dataDir*: OutDir
    storageQuota*: Natural
    blockTtlSeconds*: int
    blockMaintenanceIntervalSeconds*: int
    blockMaintenanceNumberOfBlocks*: int
    cacheSize*: Natural

proc start*(self: BlockStoreManager): Future[void] {.async.} =
  await self.repoStore.start()
  self.maintenance.start()

proc stop*(self: BlockStoreManager): Future[void] {.async.} =
  await self.repoStore.stop()
  await self.maintenance.stop()

proc getBlockStore*(self: BlockStoreManager): BlockStore =
  self.blockStore

proc createRepoStore(config: BlockStoreManagerConfig): RepoStore =
  RepoStore.new(
    repoDs = Datastore(FSDatastore.new($config.dataDir, depth = 5).expect("Should create repo data store!")),
    metaDs = SQLiteDatastore.new(config.dataDir / CodexMetaNamespace).expect("Should create meta data store!"),
    quotaMaxBytes = config.storageQuota.uint,
    blockTtl = config.blockTtlSeconds.seconds)

proc createMaintenance(repoStore: RepoStore, config: BlockStoreManagerConfig): BlockMaintainer =
  BlockMaintainer.new(
    repoStore,
    interval = config.blockMaintenanceIntervalSeconds.seconds,
    numberOfBlocksPerInterval = config.blockMaintenanceNumberOfBlocks)

proc getBlockStore(repoStore: RepoStore, config: BlockStoreManagerConfig): BlockStore =
  if config.cacheSize > 0:
    return CacheStore.new(backingStore = repoStore, cacheSize = config.cacheSize * MiB)
  return repoStore

proc new*(T: type BlockStoreManager, config: BlockStoreManagerConfig): T =
  let
    repoStore = createRepoStore(config)
    maintenance = createMaintenance(repoStore, config)
    blockStore = getBlockStore(repoStore, config)

  T(
    repoStore: repoStore,
    maintenance: maintenance,
    blockStore: blockStore)
