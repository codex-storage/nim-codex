import std/sequtils

import pkg/unittest2

import pkg/libp2p/[multicodec, multihash]
import pkg/questionable/results
import pkg/stew/byteutils

import ../examples

import pkg/codex/bittorrent/manifest/manifest
import pkg/codex/bittorrent/torrentParser

suite "torrentParser":
  test "extracts info directory bytes from the torrent binary data":
    let pieces = @[
      "21FEBA308CD51E9ACF88417193A9EA60F0F84646",
      "3D4A8279853DA2DA355A574740217D446506E8EB",
      "1AD686B48B9560B15B8843FD00E7EC1B59624B09",
      "5015E7DA0C40350624C6B5A1FED1DB39720B726C",
    ].map(
      proc(hash: string): MultiHash =
        let bytes = hash.hexToSeqByte.catch.tryGet()
        MultiHash.init($Sha1HashCodec, bytes).mapFailure.tryGet()
    )

    let info = BitTorrentInfo(
      length: 1048576, pieceLength: 262144, pieces: pieces, name: some("data1M.bin")
    )
    let encodedInfo = info.bencode()
    let infoHash = MultiHash.digest($Sha1HashCodec, encodedInfo).mapFailure.tryGet()
    let torrentBytes = ("d4:info" & string.fromBytes(encodedInfo) & "e").toBytes()
    # let torrentBytesHex = byteutils.toHex(torrentBytes)

    # check torrentBytesHex == "64343a696e666f64363a6c656e677468693130343835373665343a6e616d6531303a64617461314d2e62696e31323a7069656365206c656e6774686932363231343465363a70696563657338303a21feba308cd51e9acf88417193a9ea60f0f846463d4a8279853da2da355a574740217d446506e8eb1ad686b48b9560b15b8843fd00e7ec1b59624b095015e7da0c40350624c6b5a1fed1db39720b726c6565"

    let infoBytes = extractInfoFromTorrent(torrentBytes).tryGet()

    # echo string.fromBytes(infoBytes)

    # let infoBytesHex = byteutils.toHex(infoBytes)

    # check infoBytesHex == "64363a6c656e677468693130343835373665343a6e616d6531303a64617461314d2e62696e31323a7069656365206c656e6774686932363231343465363a70696563657338303a21feba308cd51e9acf88417193a9ea60f0f846463d4a8279853da2da355a574740217d446506e8eb1ad686b48b9560b15b8843fd00e7ec1b59624b095015e7da0c40350624c6b5a1fed1db39720b726c65"

    let extractedInfoHash =
      MultiHash.digest($Sha1HashCodec, infoBytes).mapFailure.tryGet()

    check extractedInfoHash == infoHash
