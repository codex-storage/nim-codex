{.push raises: [].}

import pkg/libp2p
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

import ../../merkletree/codex/codex
import ../../utils/json

import ../../errors
import ../../codextypes
import ../bencoding

type
  BitTorrentInfo* = ref object
    length* {.serialize.}: uint64
    pieceLength* {.serialize.}: uint32
    pieces* {.serialize.}: seq[MultiHash]
    name* {.serialize.}: ?string

  BitTorrentManifest* = ref object
    info* {.serialize.}: BitTorrentInfo
    codexManifestCid* {.serialize.}: Cid

proc `$`*(self: BitTorrentInfo): string =
  "BitTorrentInfo(length: " & $self.length & ", pieceLength: " & $self.pieceLength &
    ", pieces: " & $self.pieces & ", name: " & $self.name & ")"

proc `$`*(self: BitTorrentManifest): string =
  "BitTorrentManifest(info: " & $self.info & ", codexManifestCid: " &
    $self.codexManifestCid & ")"

func `==`*(a: BitTorrentInfo, b: BitTorrentInfo): bool =
  a.length == b.length and a.pieceLength == b.pieceLength and a.pieces == b.pieces and
    a.name == b.name

func `==`*(a: BitTorrentManifest, b: BitTorrentManifest): bool =
  a.info == b.info and a.codexManifestCid == b.codexManifestCid

proc newBitTorrentManifest*(
    info: BitTorrentInfo, codexManifestCid: Cid
): BitTorrentManifest =
  BitTorrentManifest(info: info, codexManifestCid: codexManifestCid)

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

func buildMultiHash*(_: type BitTorrentInfo, input: string): ?!MultiHash =
  without bytes =? input.hexToSeqByte.catch, err:
    return failure err.msg
  without hash =? MultiHash.init(bytes):
    without mhashMetaSha1 =? Sha1HashCodec.mhash, err:
      return failure err.msg
    if bytes.len == mhashMetaSha1.size:
      without hash =? MultiHash.init($Sha1HashCodec, bytes).mapFailure, err:
        return failure err.msg
      return success hash
    without mhashMetaSha256 =? Sha256HashCodec.mhash, err:
      return failure err.msg
    if bytes.len == mhashMetaSha256.size:
      without hash =? MultiHash.init($Sha256HashCodec, bytes).mapFailure, err:
        return failure err.msg
      return success hash
    return failure "given bytes is not a correct multihash"
  return success hash
