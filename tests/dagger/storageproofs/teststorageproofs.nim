import std/os

import pkg/questionable
import pkg/questionable/results

import pkg/chronos
import pkg/asynctest

import pkg/dagger/storageproofs
import pkg/dagger/stores
import pkg/dagger/manifest
import pkg/dagger/rng

import ../helpers

suite "Storage Proofs":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name
    blocks = 100

  var
    storageProofs: StorageProofs
    chunker = RandomChunker.new(Rng.instance(), size = BlockSize * blocks, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    store = CacheStore.new(cacheSize = BlockSize * blocks, chunkSize = BlockSize)
    rng = Rng.instance
    porDir: string

  setup:
    porDir = path.parentDir / "data" / "por"
    createDir(porDir)

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      check (await store.putBlock(blk))

    storageProofs = StorageProofs.init(store, nil, porDir)

  teardown:
    removeDir(porDir.parentDir)

  test "Storage Proofs Setup":
    (await storageProofs.setupProofs(manifest)).tryGet()
