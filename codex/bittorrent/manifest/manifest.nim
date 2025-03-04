import pkg/libp2p
import pkg/questionable
import pkg/questionable/results

import ../../errors
import ../../codextypes
import ../bencoding

type
  BitTorrentPiece* = MultiHash
  BitTorrentInfo* = ref object
    length*: uint64
    pieceLength*: uint32
    pieces*: seq[BitTorrentPiece]
    name*: ?string

  BitTorrentInfoHash* = MultiHash
  BitTorrentInfoHashV1* = distinct array[20, byte]

  BitTorrentManifest* = ref object
    info*: BitTorrentInfo
    codexManifestCid*: Cid

proc newBitTorrentManifest*(
    info: BitTorrentInfo, codexManifestCid: Cid
): BitTorrentManifest =
  BitTorrentManifest(info: info, codexManifestCid: codexManifestCid)

# needed to be able to create a MultiHash from BitTorrentInfoHashV1
proc init*(
  mhtype: typedesc[MultiHash], hashname: string, bdigest: BitTorrentInfoHashV1
): MhResult[MultiHash] {.borrow.}

func bencode*(info: BitTorrentInfo): seq[byte] =
  # flatten pieces
  var pieces: seq[byte]
  for mh in info.pieces:
    pieces.add(mh.data.buffer.toOpenArray(mh.dpos, mh.dpos + mh.size - 1))
  result = @['d'.byte]
  result.add(bencode("length") & bencode(info.length))
  if name =? info.name:
    result.add(bencode("name") & bencode(name))
  result.add(bencode("piece length") & bencode(info.pieceLength))
  result.add(bencode("pieces") & bencode(pieces))
  result.add('e'.byte)

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
  let infoBencoded = bencode(self.info)
  without infoHash =? MultiHash.digest($Sha1HashCodec, infoBencoded).mapFailure, err:
    return failure(err.msg)
  without cidInfoHash =? cid.mhash.mapFailure, err:
    return failure(err.msg)
  return success(infoHash == cidInfoHash)
