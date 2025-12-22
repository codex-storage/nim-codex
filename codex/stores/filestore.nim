import std/os
import std/posix
import std/strformat

import ../manifest/manifest
import ../blocktype
import ../utils
import ../utils/json

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p/[cid, multihash, multicodec]
import pkg/questionable/results

import ../errors
import ../units
import ../blocktype
import ../indexingstrategy
import ../logutils

const DefaultBlockSize*: uint = 65536

type FileStore* = object
  root*: string

type File* = object
  manifest: Manifest
  filepath: string
  fd*: cint

proc allocFile*(filepath: string, size: int): ?!cint =
  let fd = open(filepath, O_CREAT or O_RDWR or O_TRUNC, 0o644)
  if fd < 0:
    return failure(&"open failed with error {fd}")

  let rc = posix_fallocate(fd, 0, size)
  if rc != 0:
    return failure(&"posix_fallocate failed with error {rc}")

  success(fd)

proc openFile*(filepath: string): ?!cint =
  let fd = open(filepath, O_RDWR)
  if fd < 0:
    return failure(&"open failed with error {fd}")

  success(fd)

proc initDataset*(filepath: string, manifest: Manifest): ?!File =
  let fd =
    ?(
      if fileExists(filepath): openFile(filepath)
      else: allocFile(filepath, manifest.datasetSize.int)
    )
  success(File(manifest: manifest, filepath: filepath, fd: fd))

proc ensureOpen*(self: File): ?!void =
  if self.fd < 0:
    return failure("dataset is not open")
  success()

proc getBlock*(
    self: File, index: int
): Future[?!Block] {.async: (raises: [CatchableError]).} =
  ?self.ensureOpen()

  if index > self.manifest.blocksCount:
    return failure(&"index out of bounds")

  let
    blockSize = self.manifest.blockSize.int
    offset = index * blockSize
    buf = newSeqWith(blockSize, 0.byte)
    rc = pread(self.fd, addr(buf[0]), blockSize, offset)

  if rc != blockSize:
    return failure(&"pread failed with error {rc}")

  Block.new(data = buf)

proc putBlock*(
    self: File, index: int, blk: Block
): Future[?!void] {.async: (raises: [CatchableError]).} =
  ?self.ensureOpen()

  if index > self.manifest.blocksCount:
    return failure(&"index out of bounds")

  let
    blockSize = self.manifest.blockSize.int
    offset = index * blockSize
    rc = pwrite(self.fd, addr(blk.data[0]), blockSize, offset)

  if rc != blockSize:
    return failure(&"pwrite failed with error {rc}")

  success()

proc create*(self: FileStore, manifest: Manifest): ?!File =
  let path = self.root & "/" & $manifest.treeCid
  initDataset(path, manifest)
