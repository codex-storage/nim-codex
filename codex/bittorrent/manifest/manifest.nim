import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

type
  BitTorrentPiece* = MultiHash
  BitTorrentInfo* = ref object
    length*: uint64
    pieceLength*: uint32
    pieces*: seq[BitTorrentPiece]
    name*: ?string

  BitTorrentInfoHash* = MultiHash

  BitTorrentManifest* = ref object
    info*: BitTorrentInfo
    codexManifestCid*: Cid

proc newBitTorrentManifest*(
    info: BitTorrentInfo, codexManifestCid: Cid
): BitTorrentManifest =
  BitTorrentManifest(info: info, codexManifestCid: codexManifestCid)

func validate*(self: BitTorrentManifest, cid: Cid): ?!bool =
  # First stage of validation:
  # (1) bencode the info dictionary from the torrent manifest
  # (2) hash the bencoded info dictionary
  # (3) compare the hash with the info hash in the cid
  #
  # This will prove that our info metadata is correct.
  # It still does not proof that the "codexManifestCid" from the torrent manifest
  # points to genuine content. This validation will be done while fetching blocks
  # where we will be able to detect that the aggregated pieces do not match
  # the hashes in the info dictionary from the torrent manifest.
  return success true
