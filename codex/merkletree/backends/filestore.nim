## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

#[
  message IndexEntry {
    int64 index = 1;
    int64 offset = 2;
  }

  message Header {
    repeated IndexEntry index = 1;
  }
]#

################################################################
##
## This implementation will store the nodes of a merkle tree
## in a file serialized with protobuf format
##
## There are several methods of constructing Merkle trees
##
## - Locally, where the root of the tree is unknown until
##   all the leaves are processed
## - By retrieving it from a remote node, in which case, the
##   leaf will be accompanied by a path all the way to the root,
##   but it might arrive out of order.
##
## The requirements are thus:
##
## - Graceful and efficient handling of partial trees during
##   construction, before the root is known
## - Efficient random and sequential access
## - Easily streamable for both construction and reads
##
## Constructing a tree from a stream of leaves:
##
## To construct a tree from a stream of leaves, we need to
## store the leaves in a file and keep track of their
## offsets. We address everything by their hash, but the root
## of the tree is unknown until all the leaves are processed,
## thus the tree is initially constructed in a temporary location.
## Once the root is known, the tree is "sealed".
##
## Sealing consists of:
##
## - Creating a new file in the final destination
## - Writting the header with the table of indices and offsets
## - Copying the contents of the temporary file to the new file
##
## Constructing a tree from a stream merkle paths
##
## Constructing the tree from a stream of merkle paths is similar
## to constructing it from a stream of leaves, except that the
## root of the tree is immediately known, so we can skip the temporary
## file and write directly to the final destination.
##
## No special sealing is reaquired, the file is stored under it's
## tree root.
##

import std/os
import std/tables

import pkg/chronos
import pkg/chronos/sendfile
import pkg/questionable
import pkg/questionable/results
import pkg/libp2p/varint
import pkg/libp2p/protobuf/minprotobuf

import ./merklestore
import ../../errors

type
  FileStore* = ref object of MerkleStore
    file: File
    path*: string
    offset: uint64
    bytes: uint64
    headerOffset: uint64
    offsets: Table[uint64, uint64]

proc readVarint(file: File): ?!uint64 =
  var
    buffer: array[10, byte]

  for i in 0..<buffer.len:
    if file.readBytes(buffer, i, 1) != 1:
      return failure "Cannot read varint"

    var
      varint: uint64
      length: int

    let res = PB.getUVarint(buffer.toOpenArray(0, i), length, varint)
    if res.isOk():
      return success varint

    if res.error() != VarintError.Incomplete:
      break

  return failure "Cannot parse varint"

proc writeVarint(data: openArray[byte]): seq[byte] =
  let vbytes = PB.toBytes(data.len().uint64)
  var buf = newSeqUninitialized[byte](data.len() + vbytes.len)
  buf[0..<vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len..<buf.len] = data

proc readHeader(file: File): ?!(uint64, Table[uint64, uint64]) =
  let
    len = ? file.readVarint()

  var
    header = newSeqUninitialized[byte](len.Natural)

  if file.readBytes(header, 0, len.Natural) != len.int:
    return failure "Unable to read header"

  var
    offsets: Table[uint64, uint64]
    pb = initProtoBuffer(header)
    offsetsList: seq[seq[byte]]

  if ? pb.getRepeatedField(1, offsetsList).mapFailure:
    for item in offsetsList:
      var
        offsetsPb = initProtoBuffer(item)
        index: uint64
        offset: uint64

      discard ? offsetsPb.getField(1, index).mapFailure
      discard ? offsetsPb.getField(2, offset).mapFailure

      offsets[index] = offset

  success (len, offsets)

proc writeHeader(file: File, offsets: Table[uint64, uint64]): ?!void =
  var
    pb = initProtoBuffer()

  for (index, offset) in offsets.pairs:
    var
      offsetsPb = initProtoBuffer()
      index = index
      offset = offset

    offsetsPb.write(1, index)
    offsetsPb.write(2, offset)
    offsetsPb.finish()

    pb.write(1, offsetsPb.buffer)

  pb.finish()

  var buf = pb.buffer.writeVarint()
  if file.writeBytes(buf, 0, buf.len) != buf.len:
    return failure "Cannot write header to store!"

  success()

method put*(
  self: FileStore,
  index: Natural,
  hash: seq[byte]): Future[?!void] {.async.} =
  ## Write a node to the on disk file
  ##

  var
    offset = self.offset
    pb = initProtoBuffer()

  pb.write(1, hash)
  pb.finish()

  self.offsets[index.uint64] = offset.uint64
  var buf = pb.buffer.writeVarint()
  self.offset += buf.len.uint64

  # TODO: add async file io
  if self.file.writeBytes(buf, 0, buf.len) != buf.len:
    return failure "Cannot write node to store!"

  self.bytes += buf.len.uint64
  success()

method get*(self: FileStore, index: Natural): Future[?!seq[byte]] {.async.} =
  ## Read a node from the on disk file
  ##

  let index = index.uint64
  if index notin self.offsets:
    return failure "Node doesn't exist in store!"

  let
    offset = self.offsets[index] + self.headerOffset

  self.file.setFilePos(offset.int64)
  without size =? self.file.readVarint(), err:
    return failure err

  var
    buf = newSeqUninitialized[byte](size)

  if self.file.readBytes(buf, 0, size) != size.int:
    return failure "Cannot read node from store!"

  success buf

method seal*(self: FileStore, id: string = ""): Future[?!void] {.async.} =
  if id.len <= 0:
    return success()

  let path = self.path / id

  if fileExists(path):
    return failure "File already exists!"

  let file = open(path, fmWrite)
  if (let res = file.writeHeader(self.offsets); res.isErr):
    return failure "Cannot copy file!"

  var bytes = self.bytes.int
  if sendfile(file.getFileHandle, self.file.getFileHandle, 0, bytes) != 0 or
    bytes != self.bytes.int:
    return failure "Cannot copy file!"

  success()

proc new*(_: type FileStore, file: File, path: string): ?!FileStore =
  ## Construct a filestore merkle tree backing store
  ##

  let path = ? (
    block:
      if path.isAbsolute: path
      else: getCurrentDir() / path).catch

  if not dirExists(path):
    return failure "directory does not exist: " & path

  file.setFilePos(0)

  let
    (len, offsets) = if file.getFileSize > 0:
      ? file.readHeader()
    else:
      (0, initTable[uint64, uint64]())

  success FileStore(file: file, headerOffset: len, offsets: offsets)
