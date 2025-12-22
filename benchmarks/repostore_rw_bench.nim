import std/tempfiles
import std/times
import std/random
import std/os

import pkg/chronos
import pkg/datastore

import pkg/codex/blocktype
import pkg/codex/merkletree/codex
import pkg/codex/manifest
import pkg/codex/stores/[filestore, repostore]

const
  NBlocks = 163_840
  BlockSize = 65_536
  DataDir = ""

type Dataset* = tuple[blocks: seq[Block], tree: CodexTree, manifest: Manifest]

template benchmark*(name: string, blk: untyped) =
  let t0 = epochTime()
  blk
  let elapsed = epochTime() - t0
  echo name, " ", elapsed.formatFloat(format = ffDecimal, precision = 3), " s"

proc makeRandomBlock*(size: NBytes): Block =
  let bytes = newSeqWith(size.int, rand(uint8))
  Block.new(bytes).tryGet()

proc makeDataset*(nblocks: int, blockSize: int): ?!Dataset =
  echo "Generate dataset with ", nblocks, " blocks of ", blockSize, " bytes each."

  let
    blocks = newSeqWith(nblocks, makeRandomBlock(NBytes(blockSize)))
    tree = ?CodexTree.init(blocks.mapIt(it.cid))
    treeCid = ?tree.rootCid
    manifest = Manifest.new(
      treeCid = treeCid,
      blockSize = NBytes(blockSize),
      datasetSize = NBytes(nblocks * blockSize),
    )

  return success((blocks, tree, manifest))

proc newRepostore(dataDir: string): RepoStore =
  let blockStore =
    FSDatastore.new(dataDir, depth = 5).expect("Should create repo file data store!")
  let repoStore = RepoStore.new(
    blockStore,
    LevelDbDatastore.new(dataDir / "meta").expect("Should create metadata store!"),
    quotaMaxBytes = 50_000_000_000'nb,
  )
  repoStore

proc asBlock(m: Manifest): Block =
  let mdata = m.encode().tryGet()
  Block.new(data = mdata, codec = ManifestCodec).tryGet()

proc writeData(
    dataset: Dataset, store: RepoStore
): Future[void] {.async: (raises: [CatchableError]).} =
  let (blocks, tree, manifest) = dataset

  for i in 0 ..< NBlocks:
    (await store.putBlock(blocks[i])).tryGet()

  (await store.putBlock(manifest.asBlock())).tryGet()

proc readData(
    dataset: Dataset, store: RepoStore
): Future[void] {.async: (raises: [CatchableError]).} =
  let (blocks, tree, manifest) = dataset

  for i in 0 ..< NBlocks:
    let blk = (await store.getBlock(blocks[i].cid)).tryGet()
    assert blk.cid == blocks[i].cid

proc writeData(
    dataset: Dataset, store: FileStore
): Future[void] {.async: (raises: [CatchableError]).} =
  let (blocks, tree, manifest) = dataset

  let file = store.create(manifest).tryGet()

  for i in 0 ..< NBlocks:
    (await file.putBlock(i, blocks[i])).tryGet()

proc readData(
    dataset: Dataset, store: FileStore
): Future[void] {.async: (raises: [CatchableError]).} =
  let (blocks, tree, manifest) = dataset

  let file = store.create(manifest).tryGet()

  for i in 0 ..< NBlocks:
    let blk = (await file.getBlock(i)).tryGet()
    assert blk.cid == blocks[i].cid

proc runRepostoreBench(
    dataset: Dataset
): Future[void] {.async: (raises: [CatchableError]).} =
  let
    dir = createTempDir("repostore-bench", "")
    store = newRepostore(dir)

  echo "Store dir is ", dir
  defer:
    removeDir(dir)

  benchmark "repostore write data":
    await writeData(dataset, store)

  benchmark "repostore read data":
    await writeData(dataset, store)

proc runFilestoreBench(
    dataset: Dataset
): Future[void] {.async: (raises: [CatchableError]).} =
  let
    dir = createTempDir("filestore-bench", "")
    store = FileStore(root: dir)

  echo "Store dir is ", dir
  defer:
    removeDir(dir)

  benchmark "filestore write data":
    await writeData(dataset, store)

  benchmark "filestore read data":
    await readData(dataset, store)

let dataset = makeDataset(NBlocks, BlockSize).tryGet()
waitFor runRepostoreBench(dataset)
waitFor runFilestoreBench(dataset)
