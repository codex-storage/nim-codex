import std/strutils
import std/sequtils

import pkg/stew/byteutils
import pkg/libp2p/[multicodec, multihash]
import pkg/questionable
import pkg/questionable/results

import ../errors
import ../codextypes
import ./manifest/manifest

type
  TorrentVersion* = enum
    v1
    v2
    hybrid

  MagnetLink* = ref object
    version: TorrentVersion
    infoHashV1: ?MultiHash
    infoHashV2: ?MultiHash

proc version*(self: MagnetLink): TorrentVersion =
  ## Get the version of the magnet link
  ##
  ## returns: the version of the magnet link
  result = self.version

proc infoHashV1*(self: MagnetLink): ?MultiHash =
  ## Get the info hash of the magnet link
  ##
  ## returns: the info hash of the magnet link
  result = self.infoHashV1

proc infoHashV2*(self: MagnetLink): ?MultiHash =
  ## Get the info hash of the magnet link
  ##
  ## returns: the info hash of the magnet link
  result = self.infoHashV2

proc parseMagnetLink(link: string): ?!MagnetLink =
  let prefix = "magnet:?"
  if not link.startsWith(prefix):
    return failure("Invalid magnet link format (missing 'magnet:?' prefix)")
  let infoHashParts = link[prefix.len .. ^1].split("&").filterIt(it.startsWith("xt="))
  if infoHashParts.len < 1:
    return
      failure("Invalid magnet link format (at least one info hash part is required)")
  let v1Prefix = "xt=urn:btih:"
  let v2Prefix = "xt=urn:btmh:"
  var infoHashV1 = none(MultiHash)
  var infoHashV2 = none(MultiHash)
  for infoHashPart in infoHashParts:
    # var a = infoHashPart[v1Prefix.len .. ^1]
    if infoHashPart.startsWith(v1Prefix):
      without infoHash =? BitTorrentInfo.buildMultiHash(
        infoHashPart[v1Prefix.len .. ^1]
      ), err:
        return failure("Error parsing info hash: " & err.msg)
      infoHashV1 = some(infoHash)
    elif infoHashPart.startsWith(v2Prefix):
      without infoHash =? BitTorrentInfo.buildMultiHash(
        infoHashPart[v2Prefix.len .. ^1]
      ), err:
        return failure("Error parsing info hash: " & err.msg)
      infoHashV2 = some(infoHash)

  if infoHashV1.isNone and infoHashV2.isNone:
    return failure("Invalid magnet link format (missing info hash part)")

  var version: TorrentVersion
  if infoHashV1.isSome and infoHashV2.isSome:
    version = TorrentVersion.hybrid
  elif infoHashV1.isSome:
    version = TorrentVersion.v1
  else:
    version = TorrentVersion.v2

  let magnetLink =
    MagnetLink(version: version, infoHashV1: infoHashV1, infoHashV2: infoHashV2)
  return success(magnetLink)

proc getHashHex(multiHash: MultiHash): string =
  ## Get the info hash of the magnet link as a hex string
  result = byteutils.toHex(multiHash.data.buffer[multiHash.dpos .. ^1]).toUpperAscii()

proc `$`*(self: MagnetLink): string =
  ## Convert the magnet link to a string
  ##
  ## returns: the magnet link as a string
  if self.version == TorrentVersion.hybrid:
    result =
      "magnet:?xt=urn:btih:" & (!self.infoHashV1).getHashHex() & "&xt=urn:btmh:" &
      (!self.infoHashV2).hex
  elif self.version == v1:
    result = "magnet:?xt=urn:btih:" & (!self.infoHashV1).getHashHex()
  else:
    result = "magnet:?xt=urn:btmh:" & (!self.infoHashV2).hex

proc newMagnetLink*(magnetLinkString: string): ?!MagnetLink =
  ## Create a new magnet link
  ##
  ## version: the version of the magnet link
  ## magnetLinkString: text containing the magnet link
  ##
  ## returns: a Result containing a magnet link object or a failure
  parseMagnetLink(magnetLinkString)
