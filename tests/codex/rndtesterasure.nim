import std/sequtils
import std/sugar
import std/cpuinfo

import pkg/chronos
import pkg/datastore
import pkg/questionable/results

import pkg/codex/erasure
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/blocktype as bt
import pkg/codex/utils
import pkg/codex/chunker
import pkg/taskpools

import ../asynctest
import ./helpers

suite "Erasure encode/decode":
  var store: BlockStore
  var erasure: Erasure
  var taskpool: Taskpool
  let repoTmp = TempLevelDb.new()
  let metaTmp = TempLevelDb.new()

  setup:
    let
      repoDs = repoTmp.newDb()
      metaDs = metaTmp.newDb()

    store = RepoStore.new(repoDs, metaDs)
    taskpool = Taskpool.new(num_threads = countProcessors())
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider, taskpool)

  teardown:
    await repoTmp.destroyDb()
    await metaTmp.destroyDb()

  test "Should encode/decode a file":
    let blockSize = 16.KiBs
    # for blockSize in @(1..<8).mapIt(it * 1024):
    # echo $blockSize
    

    let 
      file = open("test_file.bin")
      chunker = FileChunker.new(file = file, chunkSize = blockSize)


    let 
      k = 20.Natural
      m = 10.Natural
    
    let manifest = await storeDataGetManifest(store, chunker)

    let encoded = (await erasure.encode(manifest, k, m)).tryGet()

    let decoded = (await erasure.decode(encoded)).tryGet()

    check:
      decoded.treeCid == manifest.treeCid
      decoded.treeCid == encoded.originalTreeCid
      decoded.blocksCount == encoded.originalBlocksCount

