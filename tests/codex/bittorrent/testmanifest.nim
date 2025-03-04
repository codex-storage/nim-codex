import std/unittest

import pkg/libp2p/[cid, multicodec, multihash]
import pkg/stew/byteutils
import pkg/questionable

import ../../examples
import ../../../codex/bittorrent/manifest

suite "BitTorrent manifest":
  # In the tests below, we use an example info dictionary
  # from a valid torrent file (v1 so far).
  # {
  #   "info": {
  #     "length": 40960,
  #     "name": "data40k.bin",
  #     "piece length": 65536,
  #     "pieces": [
  #       "1cc46da027e7ff6f1970a2e58880dbc6a08992a0"
  #     ]
  #   }
  # }
  let examplePieceHash = "1cc46da027e7ff6f1970a2e58880dbc6a08992a0".hexToSeqByte
  let examplePieceMultihash = MultiHash.init($Sha1HashCodec, examplePieceHash).tryGet
  let exampleInfo = BitTorrentInfo(
    length: 40960,
    pieceLength: 65536,
    pieces: @[examplePieceMultihash],
    name: "data40k.bin".some,
  )
  let dummyCodexManifestCid = Cid.init(
    CIDv1, ManifestCodec, MultiHash.digest($Sha256HashCodec, seq[byte].example()).tryGet
  ).tryGet

  test "b-encoding info dictionary":
    let infoEncoded = bencode(exampleInfo)
    check infoEncoded ==
      "d6:lengthi40960e4:name11:data40k.bin12:piece lengthi65536e6:pieces20:".toBytes &
      examplePieceHash & @['e'.byte]
    let expectedInfoHash = "1902d602db8c350f4f6d809ed01eff32f030da95"
    check $sha1.digest(infoEncoded) == expectedInfoHash.toUpperAscii

  test "validating against info hash Cid":
    let infoHash = "1902d602db8c350f4f6d809ed01eff32f030da95".hexToSeqByte
    let infoMultiHash = MultiHash.init($Sha1HashCodec, infoHash).tryGet
    let infoHashCid = Cid.init(CIDv1, InfoHashV1Codec, infoMultiHash).tryGet
    let bitTorrentManifest = newBitTorrentManifest(
      info = exampleInfo, codexManifestCid = dummyCodexManifestCid
    )

    check bitTorrentManifest.validate(cid = infoHashCid).tryGet == true
