import std/os

import pkg/chronos
import pkg/asynctest

import pkg/codex/rng
import pkg/codex/streams
import pkg/codex/storageproofs as st
import pkg/codex/blocktype as bt

import ../helpers

const
  SectorSize = 31
  SectorsPerBlock = BlockSize div SectorSize
  DataSetSize = BlockSize * 100

suite "Test PoR store":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    repoDir: string
    porstore: st.StpStore
    por: PoR
    cid: Cid

  setupAll:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    (spk, ssk) = st.keyGen()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = bt.Block.new(chunk).tryGet()

      manifest.add(blk.cid)
      if not (await store.putBlock(blk)):
        raise newException(CatchableError, "Unable to store block " & $blk.cid)

    cid = manifest.cid.tryGet()
    por = await PoR.init(
      StoreStream.new(store, manifest),
      ssk, spk,
      BlockSize)

    repoDir = path.parentDir / "stp"
    createDir(repoDir)
    porstore = st.StpStore.init(repoDir)

  teardownAll:
    removeDir(repoDir)

  test "Should store and retrieve Storage Proof":
    check (await porstore.store(por, cid)).isOk
    check fileExists(porstore.stpPath(cid))

  test "Should retrieve Storage Proofs":
    discard (await porstore.retrieve(cid)).tryGet()
