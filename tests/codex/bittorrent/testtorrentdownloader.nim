import std/importutils # private access

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

import pkg/codex/utils/iter
import pkg/codex/logutils

import ../../asynctest
import ./helpers
import ../helpers
import ../examples

logScope:
  topics = "testtorrentdownloader"

privateAccess(TorrentPiece)
privateAccess(TorrentDownloader)

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

  const
    pieceLength = 64.KiBs.int
    blockSize = BitTorrentBlockSize.NBytes

  # this is an invariant that pieceLength is always power of two
  # and multiple of blockSize
  let numOfBlocksPerPiece = pieceLength div blockSize.int

  var
    codexManifest: Manifest
    torrentInfo: BitTorrentInfo
    torrentManifest: BitTorrentManifest

    blocks: seq[Block]
    codexManifestBlock: Block
    torrentManifestBlock: Block

    torrentDownloader: TorrentDownloader

  proc createTestData(datasetSize: int) {.async.} =
    trace "requested dataset", datasetSize
    blocks = await makeRandomBlocks(datasetSize = datasetSize, blockSize = blockSize)
    for index, blk in blocks:
      trace "block created ", index, len = blk.data.len
    codexManifest = await storeDataGetManifest(localStore, blocks)
    codexManifestBlock = (await storeCodexManifest(codexManifest, localStore)).tryGet()
    torrentInfo = (
      await torrentInfoForCodexManifest(
        localStore, codexManifest, pieceLength = pieceLength, name = "data.bin".some
      )
    ).tryGet()
    torrentManifest = newBitTorrentManifest(
      info = torrentInfo, codexManifestCid = codexManifestBlock.cid
    )
    torrentManifestBlock =
      (await storeTorrentManifest(torrentManifest, localStore)).tryGet()

  # setup:
  #   await createTestData(datasetSize = 40.KiBs.int)

  #   torrentDownloader =
  #     newTorrentDownloader(torrentManifest, codexManifest, networkStore).tryGet()

  test "correctly sets up the pieces":
    await createTestData(datasetSize = 72.KiBs.int)

    assert torrentInfo.pieces.len == 2
    assert codexManifest.blocksCount == 5

    let blocksCount = codexManifest.blocksCount
    let numOfPieces = torrentInfo.pieces.len
    # last piece can have less blocks than numOfBlocksPerPiece
    # we know how many blocks we have:
    let numOfBlocksInLastPiece = blocksCount - (numOfBlocksPerPiece * (numOfPieces - 1))

    torrentDownloader =
      newTorrentDownloader(torrentManifest, codexManifest, networkStore).tryGet()

    echo "codeManifest: ", $codexManifest
    echo "torrentInfo: ", $torrentInfo
    echo "torrentManifest: ", $torrentManifest
    echo "codexManifestBlockCid: ", $(codexManifestBlock.cid)
    echo "torrentManifestBlockCid: ", $(torrentManifestBlock.cid)

    check torrentDownloader.pieces.len == torrentInfo.pieces.len
    check torrentDownloader.numberOfBlocksPerPiece == numOfBlocksPerPiece

    for index, piece in torrentDownloader.pieces:
      assert index < numOfPieces
      let
        expectedBlockIndexStart = index * numOfBlocksPerPiece
        expectedBlockIndexEnd =
          if index < numOfPieces - 1:
            (index + 1) * numOfBlocksPerPiece - 1
          else:
            index * numOfBlocksPerPiece + numOfBlocksInLastPiece - 1
        expectedNumOfBlocksInPiece = expectedBlockIndexEnd - expectedBlockIndexStart + 1
      check piece.pieceIndex == index
      check piece.pieceHash == torrentInfo.pieces[index]
      check piece.blockIndexStart == expectedBlockIndexStart
      check piece.blockIndexEnd == expectedBlockIndexEnd
      check torrentDownloader.numberOfBlocksInPiece(index).tryGet ==
        expectedNumOfBlocksInPiece
      let blockIterator = torrentDownloader.getNewBlocksInPieceIterator(index).tryGet
      for blkIndex in expectedBlockIndexStart .. expectedBlockIndexEnd:
        check blkIndex == blockIterator.next()
      check blockIterator.finished == true
      check piece.handle.finished == false

  proc validatePiece(torrentDownloader: TorrentDownloader, pieceIndex: int) {.async.} =
    let treeCid = codexManifest.treeCid
    var pieceHashCtx: sha1
    pieceHashCtx.init()
    let blockIter = torrentDownloader.getNewBlocksInPieceIterator(pieceIndex).tryGet
    let blks = newSeq[Block]()
    while not blockIter.finished:
      let blockIndex = blockIter.next()
      let address = BlockAddress.init(treeCid, blockIndex)
      let blk = (await localStore.getBlock(address)).tryGet()
      trace "got block from local store", treeCid, blockIndex, cid = blk.cid
      pieceHashCtx.update(blk.data)
    let computedPieceHash = pieceHashCtx.finish()
    let expectedPieceHash = torrentDownloader.pieces[pieceIndex].pieceHash
    trace "comparing piece hashes", expectedPieceHash, computedPieceHash
    check expectedPieceHash == computedPieceHash
    trace "piece validated", treeCid, pieceIndex

  test "downloading pieces":
    await createTestData(datasetSize = 72.KiBs.int)

    assert torrentInfo.pieces.len == 2
    assert codexManifest.blocksCount == 5

    torrentDownloader =
      newTorrentDownloader(torrentManifest, codexManifest, networkStore).tryGet()

    # start background task
    let downloadFut = torrentDownloader.downloadPieces()

    let pieceIter = torrentDownloader.getNewPieceIterator()

    while not pieceIter.finished:
      let expectedPieceIndex = pieceIter.next()
      trace "waiting for piece", expectedPieceIndex
      let waitFut = torrentDownloader.waitForNextPiece()
      let status = await waitFut.withTimeout(1.seconds)
      assert status == true
      let pieceIndex = await waitFut
      trace "got piece", pieceIndex
      check pieceIndex == expectedPieceIndex
      await torrentDownloader.validatePiece(pieceIndex)

    check (await torrentDownloader.waitForNextPiece()) == -1
    check torrentDownloader.queue.empty
