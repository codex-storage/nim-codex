import std/sequtils

import pkg/asynctest
import pkg/chronos
import pkg/libp2p/errors
import pkg/contractabi as ca

import pkg/codex/rng
import pkg/codex/chunker
import pkg/codex/storageproofs
import pkg/codex/discovery
import pkg/codex/manifest
import pkg/codex/stores
import pkg/codex/storageproofs as st
import pkg/codex/blocktype as bt
import pkg/codex/streams

import ../examples
import ../helpers

const
  BlockSize = 31'nb * 64
  DataSetSize = BlockSize * 100

asyncchecksuite "Storage Proofs Network":
  let
    hostAddr = ca.Address.example
    blocks = toSeq([1, 5, 10, 14, 20, 12, 22]) # TODO: maybe make them random

  var
    stpNetwork1: StpNetwork
    stpNetwork2: StpNetwork
    switch1: Switch
    switch2: Switch
    discovery1: MockDiscovery
    discovery2: MockDiscovery

    chunker: RandomChunker
    manifest: Manifest
    store: BlockStore
    ssk: st.SecretKey
    spk: st.PublicKey
    porMsg: PorMessage
    cid: Cid
    porStream: StoreStream
    por: PoR
    tags: seq[Tag]

  setup:
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize.int, chunkSize = BlockSize)
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    (spk, ssk) = st.keyGen()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let blk = bt.Block.new(chunk).tryGet()
      manifest.add(blk.cid)
      (await store.putBlock(blk)).tryGet()

    cid = manifest.cid.tryGet()
    porStream = StoreStream.new(store, manifest)
    por = await PoR.init(
      porStream,
      ssk, spk,
      BlockSize.int)

    porMsg = por.toMessage()
    tags = blocks.mapIt(
      Tag(idx: it, tag: porMsg.authenticators[it]))

    switch1 = newStandardSwitch()
    switch2 = newStandardSwitch()

    discovery1 = MockDiscovery.new()
    discovery2 = MockDiscovery.new()

    stpNetwork1 = StpNetwork.new(switch1, discovery1)
    stpNetwork2 = StpNetwork.new(switch2, discovery2)

    switch1.mount(stpNetwork1)
    switch2.mount(stpNetwork2)

    await switch1.start()
    await switch2.start()

  teardown:
    await switch1.stop()
    await switch2.stop()
    await close(porStream)

  test "Should upload to host":
    var
      done = newFuture[void]()

    discovery1.findHostProvidersHandler = proc(d: MockDiscovery, host: ca.Address):
      Future[seq[SignedPeerRecord]] {.async, gcsafe.} =
        check hostAddr == host
        return @[switch2.peerInfo.signedPeerRecord]

    proc tagsHandler(msg: TagsMessage) {.async, gcsafe.} =
      check:
        Cid.init(msg.cid).tryGet() == cid
        msg.tags == tags

      done.complete()

    stpNetwork2.tagsHandle = tagsHandler
    (await stpNetwork1.uploadTags(
      cid,
      blocks,
      porMsg.authenticators,
      hostAddr)).tryGet()

    await done.wait(1.seconds)
