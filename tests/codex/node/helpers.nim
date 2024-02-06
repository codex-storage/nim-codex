
import std/times

import pkg/libp2p
import pkg/chronos

import pkg/codex/codextypes
import pkg/codex/chunker

import ../../asynctest

proc toTimesDuration*(d: chronos.Duration): times.Duration =
  initDuration(seconds = d.seconds)

proc drain*(
  stream: LPStream | Result[lpstream.LPStream, ref CatchableError]):
  Future[seq[byte]] {.async: (handleException: true, raises: [AsyncExceptionError]).} =

  let
    stream =
      when typeof(stream) is Result[lpstream.LPStream, ref CatchableError]:
        stream.tryGet()
      else:
        stream

  defer:
    await stream.close()

  var data: seq[byte]
  while not stream.atEof:
    var
      buf = newSeq[byte](DefaultBlockSize.int)
      res = await stream.readOnce(addr buf[0], DefaultBlockSize.int)
    check res <= DefaultBlockSize.int
    buf.setLen(res)
    data &= buf

  data

proc pipeChunker*(
  stream: BufferStream,
  chunker: Chunker
) {.async: (handleException: true, raises: [AsyncExceptionError]).} =
  try:
    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):
      await stream.pushData(chunk)
  finally:
    await stream.pushEof()
    await stream.close()

template setupAndTearDown*() {.dirty.} =
  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    clock: Clock
    localStore: RepoStore
    localStoreRepoDs: DataStore
    localStoreMetaDs: DataStore
    engine: BlockExcEngine
    store: NetworkStore
    node: CodexNodeRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager
    discovery: DiscoveryEngine
    erasure: Erasure

  let
    path = currentSourcePath().parentDir

  setup:
    file = open(path /../ "" /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file, chunkSize = DefaultBlockSize)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)

    clock = SystemClock.new()
    localStoreMetaDs = SQLiteDatastore.new(Memory).tryGet()
    localStoreRepoDs = SQLiteDatastore.new(Memory).tryGet()
    localStore = RepoStore.new(localStoreRepoDs, localStoreMetaDs, clock = clock)
    await localStore.start()

    blockDiscovery = Discovery.new(
      switch.peerInfo.privateKey,
      announceAddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0")
        .expect("Should return multiaddress")])
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()
    discovery = DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    engine = BlockExcEngine.new(localStore, wallet, network, discovery, peerStore, pendingBlocks)
    store = NetworkStore.new(engine, localStore)
    erasure = Erasure.new(store, leoEncoderProvider, leoDecoderProvider)
    node = CodexNodeRef.new(switch, store, engine, erasure, blockDiscovery)

    await node.start()

  teardown:
    close(file)
    await node.stop()
