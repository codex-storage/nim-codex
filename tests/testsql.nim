import std/monotimes
import os

import pkg/chronos
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/cid
import pkg/datastore

import pkg/codex/rng
import pkg/codex/chunker
import pkg/codex/blocktype as bt

import ../leveldb/leveldbds
import ../rocksdb/rocksdbds

import ./asynctest
import ./checktest
import ./helpers
import ./codex/helpers

proc setGetTest(store: DataStore) {.async.} =
  let chunker = RandomChunker.new(Rng.instance(), size = 4096000, chunkSize = 256)
  var blocks: seq[bt.Block]
  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break
    blocks.add(bt.Block.new(chunk).tryGet())

  for blk in blocks:
    let key = Key.init($blk.cid).tryGet()
    discard (await store.put(key, blk.data))
    let bytes = (await store.get(key)).tryGet()
    check:
      bytes == blk.data

proc doTest(name: string, store: DataStore) {.async.} =
  let chunker = RandomChunker.new(Rng.instance(), size = 4096000, chunkSize = 256)
  var blocks: seq[bt.Block]
  while true:
    let chunk = await chunker.getBytes()
    if chunk.len <= 0:
      break
    blocks.add(bt.Block.new(chunk).tryGet())

  let t0 = getMonoTime()
  for blk in blocks:
    let key = Key.init($blk.cid).tryGet()
    discard (await store.put(key, blk.data))

  let t1 = getMonoTime()

  var read: seq[seq[byte]]
  for blk in blocks:
    let key = Key.init($blk.cid).tryGet()
    let bytes = (await store.get(key)).tryGet()
    read.add(bytes)

  let t2 = getMonoTime()

  for i in 0..<blocks.len:
    check:
      blocks[i].data == read[i]

  setGetTest(store)

  echo name  & " = " & $(t1 - t0) & " / " & $(t2 - t1)

asyncchecksuite "SQL":
  test "should A":
    await doTest("defaultSQL", SQLiteDatastore.new("defaultSQL").tryGet())

    let dir = "defaultFS"
    if not dirExists(dir):
      createDir(dir)
    await doTest("defaultFS", FSDatastore.new(dir, depth = 5).tryGet())
    removeDir(dir)

    let ldb = LevelDbDatastore.new("ldb").tryGet()
    await doTest("leveldb", ldb)

    let rdb = RocksDbDatastore.new("rdb").tryGet()
    await doTest("rocksdb", rdb)
