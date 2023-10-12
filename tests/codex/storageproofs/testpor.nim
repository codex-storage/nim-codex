import pkg/chronos
import pkg/asynctest

import pkg/blscurve/blst/blst_abi

import pkg/codex/streams
import pkg/codex/storageproofs as st
import pkg/codex/stores
import pkg/codex/manifest
import pkg/codex/merkletree
import pkg/codex/chunker
import pkg/codex/rng
import pkg/codex/blocktype as bt

import ../helpers

const
  BlockSize = 31'nb * 4
  SectorSize = 31'nb
  SectorsPerBlock = BlockSize div SectorSize
  DataSetSize = BlockSize * 100
  CacheSize = DataSetSize * 2

asyncchecksuite "BLS PoR":
  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    porStream: SeekableStream
    proofStream: SeekableStream

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize.int, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = CacheSize, chunkSize = BlockSize)
    (spk, ssk) = st.keyGen()

    manifest = await storeDataGetManifest(store, chunker)

    porStream = SeekableStoreStream.new(store, manifest)
    proofStream = SeekableStoreStream.new(store, manifest)

  teardown:
    await close(porStream)
    await close(proofStream)

  proc createPor(): Future[PoR] =
    return PoR.init(
        porStream,
        ssk,
        spk,
        BlockSize.int)

  proc createProof(por: PoR, q: seq[QElement]): Future[Proof] =
    return generateProof(
        proofStream,
        q,
        por.authenticators,
        SectorsPerBlock)

  test "Test PoR without corruption":
    let
      por = await createPor()
      q = generateQuery(por.tau, 22)
      proof = await createProof(por, q)

    check por.verifyProof(q, proof.mu, proof.sigma)

  test "Test PoR with corruption - query: 22, corrupted blocks: 300, bytes: 10":
    let
      por = await createPor()
      pos = await store.corruptBlocks(manifest, 30, 10)
      q = generateQuery(por.tau, 22)
      proof = await createProof(por, q)

    check pos.len == 30
    check not por.verifyProof(q, proof.mu, proof.sigma)

asyncchecksuite "Test Serialization":
  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    por: PoR
    q: seq[QElement]
    proof: Proof
    porStream: SeekableStream
    proofStream: SeekableStream

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize.int, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = CacheSize, chunkSize = BlockSize)
    manifest = await storeDataGetManifest(store, chunker)

    (spk, ssk) = st.keyGen()
    porStream = SeekableStoreStream.new(store, manifest)
    por = await PoR.init(
      porStream,
      ssk,
      spk,
      BlockSize.int)
    q = generateQuery(por.tau, 22)
    proofStream = SeekableStoreStream.new(store, manifest)
    proof = await generateProof(
      proofStream,
      q,
      por.authenticators,
      SectorsPerBlock)

  teardown:
    await close(porStream)
    await close(proofStream)

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
