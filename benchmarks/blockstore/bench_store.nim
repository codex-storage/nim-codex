import std/[sequtils, strformat, os, options]
import std/[times, strutils, terminal]

import pkg/questionable
import std/random
import pkg/questionable/results
import pkg/datastore
import pkg/codex/blocktype as bt
import pkg/libp2p/[cid, multicodec]
import pkg/codex/merkletree/codex

import pkg/codex/stores/repostore/[store, types, operations]
import pkg/codex/utils
import ../utils
import ../../tests/codex/helpers

let DataDir = "/Users/rahul/Work/repos/dataDir"

var repoDs = Datastore(
  FSDatastore.new(DataDir, depth = 5).expect("Should create repo file data store!")
)
var metaDs = Datastore(
  LevelDbDatastore.new(DataDir).expect("Should create repo LevelDB data store!")
)

proc generateRandomBytes(size: int): seq[byte] =
  randomize()
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte(rand(0 .. 255))

proc createTestBlock(size: int): bt.Block =
  bt.Block.new(generateRandomBytes(size)).tryGet()

proc benchmarkRepoStore() =
  let store = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 100000000000'nb)
  waitFor store.start()
  echo "Initializing RepoStore benchmarks..."

  # Setup test data
  let
    testDataLen = 4.MiBs
    testBlk = createTestBlock(testDataLen.int)
    benchmarkLoops = 800

  var
    blcks = newSeq[Block]()
    proofs = newSeq[CodexProof]()

  for i in 0 ..< benchmarkLoops:
    var blk = createTestBlock(testDataLen.int)
    blcks.add(blk)

  let (manifest, tree) = makeManifestAndTree(blcks).tryGet()
  let treeCid = tree.rootCid.tryGet()

  echo "Manifest blocks", manifest.blocksCount

  for i in 0 ..< benchmarkLoops:
    let proof = tree.getProof(i).tryGet()
    proofs.add(proof)

  var i = 0
  # Benchmark putBlock
  benchmark fmt"put_block_{testDataLen}", benchmarkLoops:
    (waitFor store.putBlock(blcks[i])).tryGet()
    i += 1

  i = 0
  benchmark fmt"put_cid_and_proof", benchmarkLoops:
    (waitFor store.putCidAndProof(treeCid, i, blcks[i].cid, proofs[i])).tryGet()
    i += 1

  i = 0
  benchmark fmt"get_cid_and_proof", benchmarkLoops:
    discard (waitFor store.getCidAndProof(treeCid, i)).tryGet()
    i += 1

  i = 0
  benchmark fmt"has_block_{testDataLen}", benchmarkLoops:
    discard (waitFor store.hasBlock(blcks[i].cid)).tryGet()
    i += 1

  i = 0
  benchmark "get_block", benchmarkLoops:
    discard (waitFor store.getBlock(blcks[i].cid)).tryGet()
  i += 1

  i = 0
  benchmark "del_block_with_index", benchmarkLoops:
    (waitFor store.delBlock(treeCid, i.Natural)).tryGet()
    i += 1

  for i in 0 ..< benchmarkLoops:
    discard waitFor store.putBlock(blcks[i])

  i = 0
  benchmark "delete_block", benchmarkLoops:
    discard waitFor store.delBlock(blcks[i].cid)
    i += 1

  printBenchMarkSummaries()

when isMainModule:
  benchmarkRepoStore()
