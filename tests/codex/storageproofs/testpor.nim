import pkg/chronos
import pkg/asynctest

import pkg/blscurve/blst/blst_abi

import pkg/codex/streams
import pkg/codex/storageproofs as st
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/chunker
import pkg/codex/rng
import pkg/codex/blocktype as bt

import ../helpers

const
  BlockSize = 31 * 4
  SectorSize = 31
  SectorsPerBlock = BlockSize div SectorSize
  DataSetSize = BlockSize * 100

checksuite "BLS PoR":
  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    (spk, ssk) = st.keyGen()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      (await store.putBlock(blk)).tryGet()

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

suite "Test Serialization":
  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    por: PoR
    q: seq[QElement]
    proof: Proof

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      (await store.putBlock(blk)).tryGet()

    (spk, ssk) = st.keyGen()
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

  test "Serialize Public Key":
    var
      spkMessage = spk.toMessage()

    check:
      spk.signkey == spkMessage.fromMessage().tryGet().signkey
      spk.key.blst_p2_is_equal(spkMessage.fromMessage().tryGet().key).bool

  test "Serialize TauZero":
    var
      tauZeroMessage = por.tau.t.toMessage()
      tauZero = tauZeroMessage.fromMessage().tryGet()

    check:
      por.tau.t.name == tauZero.name
      por.tau.t.n == tauZero.n

    for i in 0..<por.tau.t.u.len:
      check blst_p1_is_equal(por.tau.t.u[i], tauZero.u[i]).bool

  test "Serialize Tau":
    var
      tauMessage = por.tau.toMessage()
      tau = tauMessage.fromMessage().tryGet()

    check:
      por.tau.signature == tau.signature

  test "Serialize PoR":
    let
      porMessage = por.toMessage()
      ppor = porMessage.fromMessage().tryGet()

    for i in 0..<por.authenticators.len:
      check blst_p1_is_equal(por.authenticators[i], ppor.authenticators[i]).bool

  test "Serialize Proof":
    let
      proofMessage = proof.toMessage()
      pproof = proofMessage.fromMessage().tryGet()

    check:
      proof.sigma.blst_p1_is_equal(pproof.sigma).bool
      proof.mu == pproof.mu

    check por.verifyProof(q, pproof.mu, pproof.sigma)
