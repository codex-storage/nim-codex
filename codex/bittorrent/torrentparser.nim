import std/strutils
import std/re

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/stew/base10

import ../errors

proc extractInfoFromTorrent*(torrentBytes: seq[byte]): ?!seq[byte] =
  ## Extract the info from a torrent file
  ##
  ## params:
  ##   torrentBytes: the torrent file bytes
  ##
  ## returns: the bytes containing only the content of the info dictionary
  ##          or a failure if info is not found or invalid
  let torrentStr = string.fromBytes(torrentBytes)
  if torrentStr.contains("file tree") or torrentStr.contains("piece layers"):
    return failure("Torrent v2 provided. Only v1 is currently supported.")
  let infoKeyPos = torrentStr.find("info")
  if infoKeyPos == -1:
    return failure("Torrent file does not contain info dictionary.")
  let infoStartPos = infoKeyPos + "info".len
  if torrentStr[infoStartPos] != 'd':
    return failure("Torrent file does not contain valid info dictionary.")

  var matches = newSeq[tuple[first, last: int]](1)
  let (_, piecesEndIndex) = torrentStr.findBounds(re"pieces(\d+):", matches)
  if matches.len == 1:
    let (first, last) = matches[0]
    let piecesLenStr = torrentStr[first .. last]
    without piecesLen =? Base10.decode(uint, piecesLenStr).mapFailure, err:
      return failure("Error decoding pieces length: " & err.msg)
    let piecesEndMarkerPos = piecesEndIndex + 1 + piecesLen.int
    if torrentStr[piecesEndMarkerPos] != 'e':
      return failure("Torrent file does not contain valid pieces.")
    let infoDirStr = torrentStr[infoStartPos .. piecesEndMarkerPos]
    infoDirStr.toBytes().success
  else:
    return failure("Torrent file does not contain valid pieces.")
