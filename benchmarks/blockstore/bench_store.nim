import std/[sequtils, strformat, os, options]
import std/[times, strutils, terminal, random]

import pkg/questionable
import pkg/questionable/results
import pkg/datastore
import pkg/codex/blocktype as bt
import pkg/libp2p/[cid, multicodec]
import pkg/codex/merkletree/codex

import pkg/codex/stores/repostore/[types, operations]
import pkg/codex/utils
import ../utils
import ../../tests/codex/helpers
import ../../tests/codex/node/helpers
#import std/nimprof
import std/importutils
import pkg/codex/codextypes

import pkg/chronos
import pkg/stew/byteutils
import pkg/datastore/typedds
import pkg/stint
import pkg/poseidon2
import pkg/poseidon2/io
import pkg/taskpools

import pkg/nitro
import pkg/codexdht/discv5/protocol as discv5

import pkg/codex/logutils
import pkg/codex/stores
import pkg/codex/contracts
import pkg/codex/systemclock
import pkg/codex/blockexchange
import pkg/codex/slots
import pkg/codex/manifest
import pkg/codex/discovery
import pkg/codex/erasure
import pkg/codex/merkletree
import pkg/codex/blocktype as bt

import pkg/codex/node {.all.}

privateAccess(CodexNodeRef)

let DataDir = "/Users/rahul/Work/repos/dataDir"

var repoDs = Datastore(
  FSDatastore.new(DataDir, depth = 5).expect("Should create repo file data store!")
)
var metaDs = Datastore(
  LevelDbDatastore.new(DataDir).expect("Should create repo LevelDB data store!")
)

template setupAndTearDown1*(repoDs: RepoStore) {.dirty.} =
  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    clock: Clock
    localStore: RepoStore
    engine: BlockExcEngine
    store: NetworkStore
    node1: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discoveryEn: DiscoveryEngine
    advertiser: Advertiser

  let path = currentSourcePath().parentDir

  file = open("./large_file.dat")
  chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
  switch = newStandardSwitch()
  wallet = WalletRef.new(EthPrivateKey.random())
  network = BlockExcNetwork.new(switch)

  clock = SystemClock.new()

  localStore = repoDs

  waitFor localStore.start()

  blockDiscovery = Discovery.new(
    switch.peerInfo.privateKey,
    announceAddrs =
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("Should return multiaddress")],
  )
  peerStore = PeerCtxStore.new()
  pendingBlocks = PendingBlocksManager.new()
  discoveryEn =
    DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
  advertiser = Advertiser.new(localStore, blockDiscovery)
  engine = BlockExcEngine.new(
    localStore, wallet, network, discoveryEn, advertiser, peerStore, pendingBlocks
  )
  store = NetworkStore.new(engine, localStore)
  node1 = CodexNodeRef.new(
    switch = switch,
    networkStore = store,
    engine = engine,
    prover = Prover.none,
    discovery = blockDiscovery,
    taskpool = Taskpool.new(),
  )

  # teardown:
  #   file.close()
  #   await node1.stop()
  #   await metaTmp.destroyDb()
  #   await repoTmp.destroyDb()

proc generateRandomBytes(size: int): seq[byte] =
  randomize()
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte(rand(0 .. 255))

proc createTestBlock(size: int): bt.Block =
  bt.Block.new(generateRandomBytes(size)).tryGet()

proc makeManifestBlock*(manifest: Manifest): ?!bt.Block =
  without encodedVerifiable =? manifest.encode(), err:
    trace "Unable to encode manifest"
    return failure(err)

  without blk =? bt.Block.new(data = encodedVerifiable, codec = ManifestCodec), error:
    trace "Unable to create block from manifest"
    return failure(error)

  success blk

proc storeManifest*(
    store: RepoStore, manifest: Manifest
): Future[?!bt.Block] {.async.} =
  without blk =? makeManifestBlock(manifest), err:
    trace "Unable to create manifest block", err = err.msg
    return failure(err)

  if err =? (await store.putBlock(blk)).errorOption:
    trace "Unable to store manifest block", cid = blk.cid, err = err.msg
    return failure(err)

  success blk

proc benchmarkGet(store: RepoStore, blcks: seq[bt.Block], benchmarkLoops: int) =
  var i = 0
  benchmark "get_block", benchmarkLoops:
    discard (waitFor store.getBlock(blcks[i].cid)).tryGet()
  i += 1

proc benchmarkPut(store: RepoStore, blcks: seq[bt.Block], benchmarkLoops: int) =
  var i = 0
  benchmark "put_block", benchmarkLoops:
    (waitFor store.putBlock(blcks[i])).tryGet()
  i += 1

proc benchmarkDel(store: RepoStore, blcks: seq[bt.Block], benchmarkLoops: int) =
  var i = 0
  benchmark "del_block", benchmarkLoops:
    (waitFor store.delBlock(blcks[i].cid)).tryGet()
  i += 1

proc benchmarkHas(store: RepoStore, blcks: seq[bt.Block], benchmarkLoops: int) =
  var i = 0
  benchmark "has_block", benchmarkLoops:
    discard (waitFor store.hasBlock(blcks[i].cid)).tryGet()
  i += 1

proc benchmarkDelBlockWithIndex(store: RepoStore, treeCid: Cid, benchmarkLoops: int) =
  var i = 0
  benchmark "del_cid", benchmarkLoops:
    (waitFor store.delBlock(treeCid, i.Natural)).tryGet()
  i += 1

proc benchmarkPutCidAndProof(
    store: RepoStore,
    treeCid: Cid,
    blcks: seq[bt.Block],
    proofs: seq[CodexProof],
    benchmarkLoops: int,
) =
  var i = 0
  benchmark "put_cid_and_proof", benchmarkLoops:
    (waitFor store.putCidAndProof(treeCid, i, blcks[i].cid, proofs[i])).tryGet()
  i += 1

proc benchmarkGetCidAndProof(
    store: RepoStore,
    treeCid: Cid,
    blcks: seq[bt.Block],
    proofs: seq[CodexProof],
    benchmarkLoops: int,
) =
  var i = 0
  benchmark "get_cid_and_proof", benchmarkLoops:
    discard (waitFor store.getCidAndProof(treeCid, i)).tryGet()
  i += 1

template profileFunc(fn: untyped) =
  enableProfiling()
  `fn`

proc benchmarkRepoStore(store: RepoStore) =
  #disableProfiling()
  echo "Initializing RepoStore benchmarks..."

  # Setup test data
  let
    testDataLen = 1.MiBs
    testBlk = createTestBlock(testDataLen.int)
    benchmarkLoops = 500

  var
    blcks = newSeq[bt.Block]()
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

  benchmarkPut(store, blcks, benchmarkLoops)

  benchmarkPutCidAndProof(store, treeCid, blcks, proofs, benchmarkLoops)
  benchmarkGetCidAndProof(store, treeCid, blcks, proofs, benchmarkLoops)

  benchmarkHas(store, blcks, benchmarkLoops)
  benchmarkGet(store, blcks, benchmarkLoops)

  benchmarkDelBlockWithIndex(store, treeCid, benchmarkLoops)

  benchmarkPut(store, blcks, benchmarkLoops)
  benchmarkDel(store, blcks, benchmarkLoops)

proc benchStore(store: RepoStore, node: CodexNodeRef, file: File) =
  benchmark "store", 1:
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)
        # Let's check that node.store can correctly rechunk these odd chunks
      oddChunker = FileChunker.new(file = file, chunkSize = 1024.NBytes, pad = false)
        # don't pad, so `node.store` gets the correct size

    var original: seq[byte]
    try:
      while (let chunk = waitFor oddChunker.getBytes(); chunk.len > 0):
        original &= chunk
        waitFor stream.pushData(chunk)
    finally:
      waitFor stream.pushEof()
      waitFor stream.close()

proc benchDeleteEntireFile(store: RepoStore, node: CodexNodeRef) =
  var blocks = newSeq[bt.Block]()

  for i in 0 ..< 16000:
    var blk = createTestBlock(64.KiBs.int)
    blocks.add(blk)

  let
    manifest = waitFor storeDataGetManifest(store, blocks)
    manifestBlock = (waitFor store.storeManifest(manifest)).tryGet()
    manifestCid = manifestBlock.cid
  benchmark "delete_entire_manifest", 1:
    echo "Deleting manifest"
    (waitFor node.delete(manifestCid)).tryGet()

proc benchGetEntireFile(store: RepoStore, node: CodexNodeRef, chunker: Chunker) =
  var blocks = newSeq[bt.Block]()

  for i in 0 ..< 16000:
    var blk = createTestBlock(64.KiBs.int)
    blocks.add(blk)

  let
    manifest = waitFor storeDataGetManifest(store, blocks)
    manifestBlk =
      bt.Block.new(data = manifest.encode().tryGet, codec = ManifestCodec).tryGet()

  (waitFor store.putBlock(manifestBlk)).tryGet()
  benchmark "retrieve_entire_manifest", 1:
    let data = waitFor ((waitFor node.retrieve(manifestBlk.cid)).tryGet()).drain()

when isMainModule:
  var rng = initRand(int64 0xDECAF)
  # disableProfiling()
  # create repo store
  let repoStore = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 100000000000'nb)
  waitFor repoStore.start()

  benchmarkRepoStore(repoStore)

  setupAndTearDown1(repoStore)
  waitFor node1.start()

  benchDeleteEntireFile(repoStore, node1)
  benchStore(repoStore, node1, file)
  benchGetEntireFile(repoStore, node1, chunker)

  printBenchMarkSummaries()

  file.close()
  waitFor node1.stop()

  # var testBlk = createTestBlock(64.KiBs.int)
  # (waitFor repoStore.putBlock(testBlk)).tryGet()

  # enableProfiling()
  # let msg128B = newSeqWith(64000, byte rng.rand(255))
  # profileFunc: 
  #   benchmark "nimcrypto_sha256", 50:
  #     discard sha256.digest(msg128B)

  # profileFunc: 
  #   benchmark "MultiHash_sha256", 50:
  #     discard MultiHash.digest($Sha256HashCodec, msg128B).mapFailure
