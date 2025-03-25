import pkg/libp2p/[cid, multicodec, multihash]
import pkg/questionable/results

import pkg/codex/rng
import pkg/codex/blockexchange
import pkg/codex/stores
import pkg/codex/discovery
import pkg/codex/blocktype

import pkg/codex/manifest
import pkg/codex/bittorrent/manifest
import pkg/codex/bittorrent/torrentdownloader

import ../../asynctest
import ./helpers
import ../helpers
import ../examples

template setupDependencies() {.dirty.} =
  var
    rng: Rng
    seckey: PrivateKey
    peerId: PeerId
    wallet: WalletRef
    blockDiscovery: Discovery
    peerStore: PeerCtxStore
    pendingBlocks: PendingBlocksManager

    network: BlockExcNetwork
    localStore: CacheStore
    discovery: DiscoveryEngine
    advertiser: Advertiser
    engine: BlockExcEngine
    networkStore: NetworkStore

  setup:
    rng = Rng.instance()
    seckey = PrivateKey.random(rng[]).tryGet()
    peerId = PeerId.init(seckey.getPublicKey().tryGet()).tryGet()
    wallet = WalletRef.example
    blockDiscovery = Discovery.new()
    peerStore = PeerCtxStore.new()
    pendingBlocks = PendingBlocksManager.new()

    network = BlockExcNetwork()
    localStore = CacheStore.new(chunkSize = BitTorrentBlockSize.NBytes)
    discovery =
      DiscoveryEngine.new(localStore, peerStore, network, blockDiscovery, pendingBlocks)
    advertiser = Advertiser.new(localStore, blockDiscovery)
    engine = BlockExcEngine.new(
      localStore, wallet, network, discovery, advertiser, peerStore, pendingBlocks
    )
    networkStore = NetworkStore.new(engine, localStore)

asyncchecksuite "Torrent Downloader":
  setupDependencies()

  var
    codexManifest: Manifest
    torrentInfo: BitTorrentInfo
    torrentManifest: BitTorrentManifest

    blocks: seq[Block]
    codexManifestBlock: Block
    torrentManifestBlock: Block

    torrentDownloader: TorrentDownloader

  proc createTestData(datasetSize: int) {.async.} =
    echo "datasetSize: ", datasetSize
    blocks = await makeRandomBlocks(
      datasetSize = datasetSize, blockSize = BitTorrentBlockSize.NBytes
    )
    for blk in blocks:
      echo "block: ", blk.data.len
    codexManifest = await storeDataGetManifest(localStore, blocks)
    codexManifestBlock = (await storeCodexManifest(codexManifest, localStore)).tryGet()
    torrentInfo = (
      await torrentInfoForCodexManifest(
        localStore, codexManifest, pieceLength = 64.KiBs.int, name = "data.bin".some
      )
    ).tryGet()
    torrentManifest = newBitTorrentManifest(
      info = torrentInfo, codexManifestCid = codexManifestBlock.cid
    )
    torrentManifestBlock =
      (await storeTorrentManifest(torrentManifest, localStore)).tryGet()

  setup:
    await createTestData(datasetSize = 40.KiBs.int)

    torrentDownloader =
      newTorrentDownloader(torrentManifest, codexManifest, networkStore).tryGet()

  test "correctly sets up the download queue":
    echo "codeManifest: ", $codexManifest
    echo "torrentInfo: ", $torrentInfo
    echo "torrentManifest: ", $torrentManifest
    echo "codexManifestBlockCid: ", $(codexManifestBlock.cid)
    echo "torrentManifestBlockCid: ", $(torrentManifestBlock.cid)
