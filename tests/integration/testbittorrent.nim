import std/net
import std/strformat
import std/sequtils
import std/json except `%`, `%*`
import pkg/nimcrypto
from pkg/libp2p import `==`, `$`, MultiHash, init, digest, hex
import pkg/codex/units
import pkg/codex/utils/iter
import pkg/codex/manifest
import pkg/codex/rest/json
import pkg/codex/bittorrent/manifest
import ./twonodes
import ../examples
import ../codex/examples

proc createInfoDictionaryForContent(
    content: seq[byte], pieceLength = DefaultPieceLength.int, name = string.none
): ?!BitTorrentInfo =
  let
    numOfBlocksPerPiece = pieceLength div BitTorrentBlockSize.int
    numOfPieces = divUp(content.len.NBytes, pieceLength.NBytes)

  var
    pieces: seq[MultiHash]
    pieceHashCtx: sha1
    pieceIter = Iter[int].new(0 ..< numOfBlocksPerPiece)

  pieceHashCtx.init()

  let chunks = content.distribute(num = numOfPieces, spread = false)

  for chunk in chunks:
    if chunk.len == 0:
      break
    if pieceIter.finished:
      without mh =? MultiHash.init($Sha1HashCodec, pieceHashCtx.finish()).mapFailure,
        err:
        return failure(err)
      pieces.add(mh)
      pieceIter = Iter[int].new(0 ..< numOfBlocksPerPiece)
      pieceHashCtx.init()
    pieceHashCtx.update(chunk)
    discard pieceIter.next()

  without mh =? MultiHash.init($Sha1HashCodec, pieceHashCtx.finish()).mapFailure, err:
    return failure(err)
  pieces.add(mh)

  let info = BitTorrentInfo(
    length: content.len.uint64,
    pieceLength: pieceLength.uint32,
    pieces: pieces,
    name: name,
  )

  success info

twonodessuite "BitTorrent API":
  setup:
    # why we do not seem to need this? yet it is twice as fast with this
    let infoPeer1 = (await client1.info()).tryGet
    let peerId1 = infoPeer1["id"].getStr()
    let announceAddress1 = infoPeer1["announceAddresses"][0].getStr()
    (await client2.connect(peerId1, announceAddress1)).tryGet

  test "uploading and downloading the content", twoNodesConfig:
    let exampleContent = exampleString(100)
    let infoHash = (await client1.uploadTorrent(exampleContent)).tryGet
    let downloadedContent = (await client2.downloadTorrent(infoHash)).tryGet
    check downloadedContent == exampleContent

  test "downloading content using magnet link", twoNodesConfig:
    let exampleContent = exampleString(100)
    let multiHash = (await client1.uploadTorrent(exampleContent)).tryGet
    let infoHash = byteutils.toHex(multiHash.data.buffer[multiHash.dpos .. ^1])
    let magnetLink = fmt"magnet:?xt=urn:btih:{infoHash}"
    let downloadedContent = (await client2.downloadTorrent(magnetLink)).tryGet
    check downloadedContent == exampleContent

  test "downloading content using torrent file", twoNodesConfig:
    let exampleFileName = "example.txt"
    let exampleContent = exampleString(100)
    let multiHash = (
      await client1.uploadTorrent(
        contents = exampleContent,
        filename = some exampleFileName,
        contentType = "text/plain",
      )
    ).tryGet

    let expectedInfo = createInfoDictionaryForContent(
      content = exampleContent.toBytes, name = some exampleFileName
    ).tryGet

    let expectedInfoBencoded = expectedInfo.bencode()
    let expectedMultiHash =
      MultiHash.digest($Sha1HashCodec, expectedInfoBencoded).mapFailure.tryGet()

    assert expectedMultiHash == multiHash

    let torrentFileContent = "d4:info" & string.fromBytes(expectedInfoBencoded) & "e"

    let downloadedContent = (
      await client2.downloadTorrent(
        contents = torrentFileContent,
        contentType = "application/octet-stream",
        endpoint = "torrent-file",
      )
    ).tryGet
    check downloadedContent == exampleContent

  test "downloading content using torrent file (JSON format)", twoNodesConfig:
    let exampleFileName = "example.txt"
    let exampleContent = exampleString(100)
    let multiHash = (
      await client1.uploadTorrent(
        contents = exampleContent,
        filename = some exampleFileName,
        contentType = "text/plain",
      )
    ).tryGet

    let expectedInfo = createInfoDictionaryForContent(
      content = exampleContent.toBytes, name = some exampleFileName
    ).tryGet

    let expectedInfoBencoded = expectedInfo.bencode()
    let expectedMultiHash =
      MultiHash.digest($Sha1HashCodec, expectedInfoBencoded).mapFailure.tryGet()

    assert expectedMultiHash == multiHash

    let infoJson = %*{"info": %expectedInfo}

    let torrentJson = $infoJson

    let downloadedContent = (
      await client2.downloadTorrent(
        contents = torrentJson,
        contentType = "application/json",
        endpoint = "torrent-file",
      )
    ).tryGet
    check downloadedContent == exampleContent

  test "uploading and downloading the content (exactly one piece long)", twoNodesConfig:
    let numOfBlocksPerPiece = int(DefaultPieceLength div BitTorrentBlockSize)
    let bytes = await RandomChunker.example(
      blocks = numOfBlocksPerPiece, blockSize = BitTorrentBlockSize.int
    )

    let infoHash = (await client1.uploadTorrent(bytes)).tryGet
    let downloadedContent = (await client2.downloadTorrent(infoHash)).tryGet
    check downloadedContent.toBytes == bytes

  test "uploading and downloading the content (exactly two pieces long)", twoNodesConfig:
    let numOfBlocksPerPiece = int(DefaultPieceLength div BitTorrentBlockSize)
    let bytes = await RandomChunker.example(
      blocks = numOfBlocksPerPiece * 2, blockSize = BitTorrentBlockSize.int
    )

    let infoHash = (await client1.uploadTorrent(bytes)).tryGet
    let downloadedContent = (await client2.downloadTorrent(infoHash)).tryGet
    check downloadedContent.toBytes == bytes

    # use with debugging to see the content
    # use:
    # CodexConfigs.init(nodes = 2).debug().withLogTopics("restapi", "node").some
    # in tests/integration/twonodes.nim
    # await sleepAsync(2.seconds)

  test "retrieving torrent manifest for given info hash", twoNodesConfig:
    let exampleFileName = "example.txt"
    let exampleContent = exampleString(100)
    let infoHash = (
      await client1.uploadTorrent(
        contents = exampleContent,
        filename = some exampleFileName,
        contentType = "text/plain",
      )
    ).tryGet

    let expectedInfo = createInfoDictionaryForContent(
      content = exampleContent.toBytes, name = some exampleFileName
    ).tryGet

    let restTorrentContent =
      (await client2.downloadTorrentManifestOnly(infoHash)).tryGet
    let torrentManifest = restTorrentContent.torrentManifest
    let info = torrentManifest.info

    check info == expectedInfo

    let response = (
      await client2.downloadManifestOnly(cid = torrentManifest.codexManifestCid)
    ).tryGet

    let restContent = RestContent.fromJson(response).tryGet

    check restContent.cid == torrentManifest.codexManifestCid

    let codexManifest = restContent.manifest
    check codexManifest.datasetSize.uint64 == info.length
    check codexManifest.blockSize == BitTorrentBlockSize
    check codexManifest.filename == info.name
    check codexManifest.mimetype == "text/plain".some
