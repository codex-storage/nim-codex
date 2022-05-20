import pkg/chronos
import pkg/asynctest

import pkg/codex/streams
import pkg/codex/storageproofs/por
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/chunker
import pkg/codex/rng
import pkg/codex/blocktype as bt

import ../helpers

const
  SectorSize = 31
  SectorsPerBlock = BlockSize div SectorSize
  DataSetSize = BlockSize * 100

suite "BLS PoR":
  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: por.SecretKey
    spk: por.PublicKey

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    (spk, ssk) = por.keyGen()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = bt.Block.new(chunk).tryGet()

      manifest.add(blk.cid)
      if not (await store.putBlock(blk)):
        raise newException(CatchableError, "Unable to store block " & $blk.cid)

  test "Test PoR without corruption":
    let
      por = await PoR.init(
        StoreStream.new(store, manifest),
        ssk,
        spk,
        BlockSize)
      q = generateQuery(por.tau, 22)
      proof = await generateProof(
        StoreStream.new(store, manifest),
        q,
        por.authenticators,
        SectorsPerBlock)

    check por.verifyProof(q, proof.mu, proof.sigma)

  test "Test PoR with corruption - query: 22, corrupted blocks: 300, bytes: 10":
    let
      por = await PoR.init(
        StoreStream.new(store, manifest),
        ssk,
        spk,
        BlockSize)
      pos = await store.corruptBlocks(manifest, 30, 10)
      q = generateQuery(por.tau, 22)
      proof = await generateProof(
        StoreStream.new(store, manifest),
        q,
        por.authenticators,
        SectorsPerBlock)

    check pos.len == 30
    check not por.verifyProof(q, proof.mu, proof.sigma)
