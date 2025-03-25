{.push raises: [].}

import pkg/libp2p/cid
import pkg/libp2p/multihash
import pkg/libp2p/protobuf/minprotobuf

import pkg/questionable/results

import ../../blocktype
import ./manifest

func decode*(_: type BitTorrentManifest, data: openArray[byte]): ?!BitTorrentManifest =
  # ```protobuf
  #   Message BitTorrentManifest {
  #     Message Piece {
  #       bytes data = 1;
  #     }
  #   
  #     Message BitTorrentInfo {
  #       uint32 length = 1;
  #       uint32 pieceLength = 2;
  #       repeated Piece pieces = 3;
  #       optional string name = 4;
  #     }
  #
  #     BitTorrentInfo info = 1;
  #     bytes codexManifestCid = 2;
  # ```

  var
    pbNode = initProtoBuffer(data)
    pbInfo: ProtoBuffer
    length: uint64
    pieceLength: uint32
    pieces: seq[MultiHash]
    piecesBytes: seq[seq[byte]]
    name: string
    cidBuf = newSeq[byte]()
    codexManifestCid: Cid

  if pbNode.getField(1, pbInfo).isErr:
    return failure("Unable to decode `info` from BitTorrentManifest")

  if pbInfo.getField(1, length).isErr:
    return failure("Unable to decode `length` from BitTorrentInfo")

  if pbInfo.getField(2, pieceLength).isErr:
    return failure("Unable to decode `pieceLength` from BitTorrentInfo")

  if ?pbInfo.getRepeatedField(3, piecesBytes).mapFailure:
    for piece in piecesBytes:
      var pbPiece = initProtoBuffer(piece)
      var dataBuf = newSeq[byte]()
      if pbPiece.getField(1, dataBuf).isErr:
        return failure("Unable to decode piece `data` to MultiHash")
      without mhash =? MultiHash.init(dataBuf).mapFailure, err:
        return failure(err.msg)
      pieces.add(mhash)
  discard ?pbInfo.getField(4, name).mapFailure

  if ?pbNode.getField(2, cidBuf).mapFailure:
    without cid =? Cid.init(cidBuf).mapFailure, err:
      return failure(err.msg)
    codexManifestCid = cid

  let info = BitTorrentInfo(
    length: length,
    pieceLength: pieceLength,
    pieces: pieces,
    name: if name.len > 0: name.some else: string.none,
  )
  BitTorrentManifest(info: info, codexManifestCid: codexManifestCid).success

func decode*(_: type BitTorrentManifest, blk: Block): ?!BitTorrentManifest =
  ## Decode a manifest using `decoder`
  ##

  if not ?blk.cid.isTorrentInfoHash:
    return failure "Cid not a torrent info hash codec"

  BitTorrentManifest.decode(blk.data)
