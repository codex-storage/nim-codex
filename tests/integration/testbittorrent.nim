import std/net
import std/sequtils
import pkg/nimcrypto
from pkg/libp2p import `==`, `$`, MultiHash, init
import pkg/codex/units
import pkg/codex/utils/iter
import pkg/codex/manifest
import pkg/codex/rest/json
import pkg/codex/bittorrent/manifest
import ./twonodes
import ../examples
import ../codex/examples
import json

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

  echo "numOfBlocksPerPiece: ", numOfBlocksPerPiece
  echo "numOfPieces: ", numOfPieces
  pieceHashCtx.init()

  let chunks = content.distribute(num = numOfPieces, spread = false)

  echo "chunks: ", chunks.len

  for chunk in chunks:
    echo "chunk: ", chunk.len
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
  test "uploading and downloading the content", twoNodesConfig:
    let exampleContent = exampleString(100)
    let infoHash = client1.uploadTorrent(exampleContent).tryGet
    let downloadedContent = client1.downloadTorrent(infoHash).tryGet
    check downloadedContent == exampleContent

  test "uploading and downloading the content (exactly one piece long)", twoNodesConfig:
    let numOfBlocksPerPiece = int(DefaultPieceLength div BitTorrentBlockSize)
    let bytes = await RandomChunker.example(
      blocks = numOfBlocksPerPiece, blockSize = BitTorrentBlockSize.int
    )

    let infoHash = client1.uploadTorrent(bytes).tryGet
    let downloadedContent = client1.downloadTorrent(infoHash).tryGet
    check downloadedContent.toBytes == bytes

  test "uploading and downloading the content (exactly two pieces long)", twoNodesConfig:
    let numOfBlocksPerPiece = int(DefaultPieceLength div BitTorrentBlockSize)
    let bytes = await RandomChunker.example(
      blocks = numOfBlocksPerPiece * 2, blockSize = BitTorrentBlockSize.int
    )

    let infoHash = client1.uploadTorrent(bytes).tryGet
    let downloadedContent = client1.downloadTorrent(infoHash).tryGet
    check downloadedContent.toBytes == bytes

    # use with debugging to see the content
    # use:
    # CodexConfigs.init(nodes = 2).debug().withLogTopics("restapi", "node").some
    # in tests/integration/twonodes.nim
    # await sleepAsync(2.seconds)

  test "retrieving torrent manifest for given info hash", twoNodesConfig:
    let exampleFileName = "example.txt"
    let exampleContent = exampleString(100)
    let infoHash = client1.uploadTorrent(
      contents = exampleContent,
      filename = some exampleFileName,
      contentType = "text/plain",
    ).tryGet

    let expectedInfo = createInfoDictionaryForContent(
      content = exampleContent.toBytes, name = some exampleFileName
    ).tryGet

    let restTorrentContent = client1.downloadTorrentManifestOnly(infoHash).tryGet
    let torrentManifest = restTorrentContent.torrentManifest
    let info = torrentManifest.info

    check info == expectedInfo

    let response =
      client1.downloadManifestOnly(cid = torrentManifest.codexManifestCid).tryGet

    echo "response: ", response
    let restContent = RestContent.fromJson(response).tryGet

    check restContent.cid == torrentManifest.codexManifestCid

    let codexManifest = restContent.manifest
    check codexManifest.datasetSize.uint64 == info.length
    check codexManifest.blockSize == BitTorrentBlockSize
    check codexManifest.filename == info.name
    check codexManifest.mimetype == "text/plain".some
