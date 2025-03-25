{.push raises: [].}

import pkg/libp2p/cid
import pkg/libp2p/multihash
import pkg/libp2p/protobuf/minprotobuf

import pkg/questionable/results

import ./manifest

proc write(pb: var ProtoBuffer, field: int, value: MultiHash) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.data.buffer)
  ipb.finish()
  pb.write(field, ipb)

proc write(pb: var ProtoBuffer, field: int, value: BitTorrentInfo) =
  var ipb = initProtoBuffer()
  ipb.write(1, value.length)
  ipb.write(2, value.pieceLength)
  for piece in value.pieces:
    ipb.write(3, piece)
  if name =? value.name:
    ipb.write(4, name)
  ipb.finish()
  pb.write(field, ipb)

proc encode*(manifest: BitTorrentManifest): seq[byte] =
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

  var ipb = initProtoBuffer()
  ipb.write(1, manifest.info)
  ipb.write(2, manifest.codexManifestCid.data.buffer)
  ipb.finish()
  ipb.buffer
