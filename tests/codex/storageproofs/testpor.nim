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
  QueryLen = 22
  DataSetSize = BlockSize * 100

suite "BLS PoR":
  let
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)

  var
    manifest: Manifest
    store: BlockStore
    ssk: por.SecretKey
    spk: por.PublicKey

  setup:
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

  # TODO: quick and dirty smoke test, needs more elaborate tests
  test "Test setup":
    let
      por = await PoR.init(
        StoreStream.new(store, manifest),
        ssk,
        spk,
        BlockSize)

    let q = generateQuery(por.tau, QueryLen)
    # echo "Generated!" , " q:", q

    let
      proof = await generateProof(
        StoreStream.new(store, manifest),
        q,
        por.authenticators,
        SectorsPerBlock)

    check por.verifyProof(q, proof.mu, proof.sigma)
