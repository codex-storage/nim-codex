import std/os
import std/sequtils

import pkg/chronos
import pkg/asynctest

import pkg/codex/rng
import pkg/codex/streams
import pkg/codex/merkletree
import pkg/codex/storageproofs as st
import pkg/codex/blocktype as bt

import ../helpers

const
  BlockSize = 31'nb * 64'nb
  DataSetSize = BlockSize * 100
  CacheSize = DataSetSize * 2

asyncchecksuite "Test PoR store":
  let
    blocks = toSeq([1, 5, 10, 14, 20, 12, 22]) # TODO: maybe make them random

  var
    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    repoDir: string
    stpstore: st.StpStore
    porStream: SeekableStream
    por: PoR
    porMsg: PorMessage
    cid: Cid
    tags: seq[Tag]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize.int, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = CacheSize * 2, chunkSize = BlockSize)
    (spk, ssk) = st.keyGen()

    manifest = await storeDataGetManifest(store, chunker)

    cid = manifest.treeCid
    porStream = StoreStream.new(store, manifest)
    por = await PoR.init(
      porStream,
      ssk, spk,
      BlockSize.int)
    porMsg = por.toMessage()
    tags = blocks.mapIt(
      Tag(idx: it, tag: porMsg.authenticators[it]) )
    repoDir = getAppDir() / "stp"
    createDir(repoDir)
    stpstore = st.StpStore.init(repoDir)

  teardown:
    await close(porStream)
    removeDir(repoDir)

  test "Should store Storage Proofs":
    check (await stpstore.store(por.toMessage(), cid)).isOk
    check fileExists(stpstore.stpPath(cid) / "por")

  test "Should retrieve Storage Proofs":
    discard await stpstore.store(por.toMessage(), cid)
    check (await stpstore.retrieve(cid)).tryGet() == porMsg

  test "Should store tags":
    check (await stpstore.store(tags, cid)).isOk
    for t in tags:
      check fileExists(stpstore.stpPath(cid) / $t.idx )

  test "Should retrieve tags":
    discard await stpstore.store(tags, cid)
    check (await stpstore.retrieve(cid, blocks)).tryGet() == tags
