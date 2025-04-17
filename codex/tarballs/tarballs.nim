{.push raises: [].}

import std/os
import std/times
import std/strutils
import std/strformat
import std/sequtils
import std/streams
import std/tables

import std/random

import pkg/chronos
import pkg/questionable/results
import pkg/libp2p/[cid, multicodec, multihash]
import pkg/serde/json

import ../blocktype

proc example2*(_: type Block, size: int = 4096): ?!Block =
  let length = rand(size)
  let bytes = newSeqWith(length, rand(uint8))
  Block.new(bytes)

proc example2*(_: type Cid): ?!Cid =
  Block.example2 .? cid

const
  TUREAD* = 0o00400'u32 # read by owner */
  TUWRITE* = 0o00200'u32 # write by owner */
  TUEXEC* = 0o00100'u32 # execute/search by owner */
  TGREAD* = 0o00040'u32 # read by group */
  TGWRITE* = 0o00020'u32 # write by group */
  TGEXEC* = 0o00010'u32 # execute/search by group */
  TOREAD* = 0o00004'u32 # read by other */
  TOWRITE* = 0o00002'u32 # write by other */
  TOEXEC* = 0o00001'u32 # execute/search by other */

type
  EntryKind* = enum
    ekNormalFile = '0'
    ekDirectory = '5'

  TarballEntry* = object
    kind*: EntryKind
    name: string
    cid: Cid
    contentLength: int
    lastModified*: times.Time
    permissions*: set[FilePermission]

  Tarball* = ref object
    contents*: OrderedTable[string, TarballEntry]

  TarballError* = object of ValueError

  TarballTree* = ref object
    name*: string
    cid*: Cid
    children*: seq[TarballTree]

  # ToDo: make sure we also record files permissions, modification time, etc...
  # For now, only fileName so that we do not have to change the Codex manifest
  # right away
  OnProcessedTarFile* = proc(stream: Stream, fileName: string): Future[?!Cid] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  OnProcessedTarDir* = proc(name: string, cids: seq[Cid]): Future[?!Cid] {.
    gcsafe, async: (raises: [CancelledError])
  .}

proc `$`*(tarball: Tarball): string =
  result = "Tarball with " & $tarball.contents.len & " entries"
  for name, entry in tarball.contents.pairs:
    var lastModified: string = "(unknown)"
    try:
      let lastModified = $entry.lastModified
    except TimeFormatParseError:
      discard
    result.add(
      "\n  " &
        fmt"{name}: name = {entry.name}, {entry.kind} ({entry.contentLength} bytes) @ {lastModified} [{entry.cid}]"
    )

proc `$`*(tarballEntry: TarballEntry): string =
  ## Returns a string representation of the tarball entry.
  result = fmt"({tarballEntry.kind}, {tarballEntry.name})"

proc parseFilePermissions(permissions: uint32): set[FilePermission] =
  if defined(windows) or permissions == 0:
    # Ignore file permissions on Windows. If they are absent (.zip made on
    # Windows for example), set default permissions.
    result.incl fpUserRead
    result.incl fpUserWrite
    result.incl fpGroupRead
    result.incl fpOthersRead
  else:
    if (permissions and TUREAD) != 0:
      result.incl(fpUserRead)
    if (permissions and TUWRITE) != 0:
      result.incl(fpUserWrite)
    if (permissions and TUEXEC) != 0:
      result.incl(fpUserExec)
    if (permissions and TGREAD) != 0:
      result.incl(fpGroupRead)
    if (permissions and TGWRITE) != 0:
      result.incl(fpGroupWrite)
    if (permissions and TGEXEC) != 0:
      result.incl(fpGroupExec)
    if (permissions and TOREAD) != 0:
      result.incl(fpOthersRead)
    if (permissions and TOWRITE) != 0:
      result.incl(fpOthersWrite)
    if (permissions and TOEXEC) != 0:
      result.incl(fpOthersExec)

proc toUnixPath(path: string): string =
  path.replace('\\', '/')

proc clear*(tarball: Tarball) =
  tarball.contents.clear()

proc openStreamImpl(
    tarball: Tarball, stream: Stream, onProcessedTarFile: OnProcessedTarFile = nil
): Future[?!void] {.async: (raises: []).} =
  tarball.clear()

  proc trim(s: string): string =
    for i in 0 ..< s.len:
      if s[i] == '\0':
        return s[0 ..< i]
    s

  try:
    var data = stream.readAll() # TODO: actually treat as a stream

    var pos: int
    while pos < data.len:
      if pos + 512 > data.len:
        return failure("Attempted to read past end of file, corrupted tarball?")

      let
        header = data[pos ..< pos + 512]
        fileName = header[0 ..< 100].trim()

      pos += 512

      if fileName.len == 0:
        continue

      let
        fileSize =
          try:
            parseOctInt(header[124 .. 134])
          except ValueError:
            raise newException(TarballError, "Unexpected error while opening tarball")
        lastModified =
          try:
            parseOctInt(header[136 .. 146])
          except ValueError:
            raise newException(TarballError, "Unexpected error while opening tarball")
        typeFlag = header[156]
        fileMode =
          try:
            parseOctInt(header[100 ..< 106])
          except ValueError:
            raise newException(
              TarballError, "Unexpected error while opening tarball (mode)"
            )
        fileNamePrefix =
          if header[257 ..< 263] == "ustar\0":
            header[345 ..< 500].trim()
          else:
            ""

      if pos + fileSize > data.len:
        return failure("Attempted to read past end of file, corrupted tarball?")

      let normalizedFileName = normalizePathEnd(fileName)
      if typeFlag == '0' or typeFlag == '\0':
        if not onProcessedTarFile.isNil:
          let stream = newStringStream(data[pos ..< pos + fileSize])
          without cid =? await onProcessedTarFile(stream, normalizedFileName), err:
            return failure(err.msg)
          tarball.contents[(fileNamePrefix / fileName).toUnixPath()] = TarballEntry(
            kind: ekNormalFile,
            name: normalizedFileName,
            contentLength: fileSize,
            cid: cid,
            lastModified: initTime(lastModified, 0),
            permissions: parseFilePermissions(cast[uint32](fileMode)),
          )
      elif typeFlag == '5':
        tarball.contents[normalizePathEnd((fileNamePrefix / fileName).toUnixPath())] = TarballEntry(
          kind: ekDirectory,
          name: normalizedFileName,
          lastModified: initTime(lastModified, 0),
          permissions: parseFilePermissions(cast[uint32](fileMode)),
        )

      # Move pos by fileSize, where fileSize is 512 byte aligned
      pos += (fileSize + 511) and not 511
    success()
  except CatchableError as e:
    return failure(e.msg)

proc open*(
    tarball: Tarball, bytes: string, onProcessedTarFile: OnProcessedTarFile = nil
): Future[?!void] {.async: (raw: true, raises: []).} =
  let stream = newStringStream(bytes)
  tarball.openStreamImpl(stream, onProcessedTarFile)

proc open*(
    tarball: Tarball, stream: Stream, onProcessedTarFile: OnProcessedTarFile = nil
): Future[?!void] {.async: (raw: true, raises: []).} =
  tarball.openStreamImpl(stream, onProcessedTarFile)

proc processDirEntries*(tarball: Tarball): Table[string, seq[TarballEntry]] =
  result = initTable[string, seq[TarballEntry]]()
  for name, entry in tarball.contents.pairs:
    let path = normalizePathEnd(name)
    if not isRootDir(path):
      let (head, _) = splitPath(path)
      result.withValue(head, value):
        value[].add(entry)
      do:
        result[head] = @[entry]

proc findRootDir*(tarball: Tarball): ?!string =
  var rootDir = ""
  for entry in tarball.contents.values:
    if entry.kind == ekDirectory:
      if isRootDir(entry.name):
        return success(entry.name)
  failure("No root directory found in tarball")

proc buildTree*(
    root: string,
    dirs: Table[string, seq[TarballEntry]],
    onProcessedTarDir: OnProcessedTarDir = nil,
): Future[?!TarballTree] {.async: (raises: [CancelledError]).} =
  let tree = TarballTree(name: root.lastPathPart, children: @[])
  let entries = dirs.getOrDefault(root)
  for entry in entries:
    if entry.kind == ekDirectory:
      without subTree =?
        await buildTree(root = entry.name, dirs = dirs, onProcessedTarDir), err:
        return failure(err.msg)
      # compute Cid for the subtree
      # let cids = subTree.children.mapIt(it.cid)
      # if not onProcessedTarDir.isNil:
      #   without cid =? await onProcessedTarDir(subTree.name, cids), err:
      #     return failure(err.msg)
      #   subTree.cid = cid
      tree.children.add(subTree)
    else:
      let child =
        TarballTree(name: entry.name.lastPathPart, children: @[], cid: entry.cid)
      tree.children.add(child)
  let cids = tree.children.mapIt(it.cid)
  if not onProcessedTarDir.isNil:
    without cid =? await onProcessedTarDir(tree.name, cids), err:
      return failure(err.msg)
    tree.cid = cid
  success(tree)

proc preorderTraversal*(root: TarballTree, json: JsonNode) =
  echo root.name
  let jsonObj = newJObject()
  jsonObj["name"] = newJString(root.name)
  jsonObj["cid"] = newJString($root.cid)
  json.add(jsonObj)
  if root.children.len > 0:
    let jsonArray = newJArray()
    jsonObj["children"] = jsonArray
    for child in root.children:
      preorderTraversal(child, jsonArray)
