## Logos Storage
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import std/tables
import std/sugar

import pkg/libp2p/multicodec
import pkg/libp2p/multihash
import pkg/libp2p/cid
import pkg/results
import pkg/questionable/results

import ./units
import ./errors

export tables

func isPowerOfTwo*(x: uint64): bool =
  (x > 0) and ((x and (x - 1)) == 0)

const
  # Block size limits for storage / network exchange
  MinBlockSize* = 4096'u64 # 4 KiB minimum
  MaxBlockSize* = 524288'u64 # 512 KiB maximum
  DefaultBlockSize* = NBytes 65536 # 64 KiB default

  # Manifest field limits (ensure manifest fits in MinBlockSize)
  MaxFilenameSize* = 255
  MaxMimetypeSize* = 128

static:
  # Validate block size constants are powers of two
  doAssert isPowerOfTwo(MinBlockSize), "MinBlockSize must be a power of two"
  doAssert isPowerOfTwo(MaxBlockSize), "MaxBlockSize must be a power of two"
  doAssert isPowerOfTwo(DefaultBlockSize.uint64),
    "DefaultBlockSize must be a power of two"

const
  # hashes
  Sha256HashCodec* = multiCodec("sha2-256")

  ManifestCodec* = multiCodec("storage-manifest")
  DatasetRootCodec* = multiCodec("storage-root")
  BlockCodec* = multiCodec("storage-block")

  StoragePrimitivesCodecs* = [ManifestCodec, DatasetRootCodec, BlockCodec]

proc initEmptyCidTable(): ?!Table[(CidVersion, MultiCodec, MultiCodec), Cid] =
  ## Initialize padding blocks table
  ##
  ## TODO: Ideally this is done at compile time, but for now
  ## we do it at runtime because of an `importc` error that is
  ## coming from somewhere in MultiHash that I can't track down.
  ##

  let
    emptyData: seq[byte] = @[]
    PadHashes = {
      Sha256HashCodec: ?MultiHash.digest($Sha256HashCodec, emptyData).mapFailure
    }.toTable

  var table = initTable[(CidVersion, MultiCodec, MultiCodec), Cid]()

  for hcodec, mhash in PadHashes.pairs:
    table[(CIDv1, hcodec, BlockCodec)] = ?Cid.init(CIDv1, BlockCodec, mhash).mapFailure

  success table

proc emptyCid*(version: CidVersion, hcodec: MultiCodec, dcodec: MultiCodec): ?!Cid =
  ## Returns cid representing empty content,
  ## given cid version, hash codec and data codec
  ##

  var table {.global, threadvar.}: Table[(CidVersion, MultiCodec, MultiCodec), Cid]

  once:
    table = ?initEmptyCidTable()

  table[(version, hcodec, dcodec)].catch

proc emptyDigest*(
    version: CidVersion, hcodec: MultiCodec, dcodec: MultiCodec
): ?!MultiHash =
  ## Returns hash representing empty content,
  ## given cid version, hash codec and data codec
  ##

  emptyCid(version, hcodec, dcodec).flatMap((cid: Cid) => cid.mhash.mapFailure)
