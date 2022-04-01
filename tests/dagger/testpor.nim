## Nim-POS
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/chronos
import pkg/asynctest

import pkg/dagger/streams
import pkg/dagger/por
import pkg/dagger/stores
import pkg/dagger/manifest
import pkg/dagger/chunker
import pkg/dagger/rng
import pkg/dagger/blocktype

import ./helpers

const
  SectorSize = 31
  SectorsPerBlock = BlockSize div SectorSize
  QueryLen = 22
  DataSetSize = BlockSize * 100

proc deleteBlocks(store: BlockStore, manifest: Manifest, blks, bytes: int) {.async.} =
  var pos: seq[int]
  while true:
    if pos.len >= blks:
      break

    var i = -1
    if (i = Rng.instance.rand(manifest.len - 1); pos.find(i) >= 0):
      continue

    pos.add(i)
    var
      blk = (await store.getBlock(manifest[i])).tryGet()
      bytePos: seq[int]

    while true:
      if bytePos.len> bytes:
        break

      var ii = -1
      if (ii = Rng.instance.rand(blk.data.len - 1); bytePos.find(ii) >= 0):
        continue

      bytePos.add(ii)
      blk.data[ii] = byte 0

suite "BLS PoR":
  let
    chunker = RandomChunker.new(Rng.instance(), size = DataSetSize, chunkSize = BlockSize)

  var
    manifest: Manifest
    store: BlockStore
    ssk: por.SecretKey
    spk: por.PublicKey

  setup:
    store = CacheStore.new(cacheSize = DataSetSize, chunkSize = BlockSize)
    manifest = Manifest.new(blockSize = BlockSize).tryGet()
    (spk, ssk) = por.keyGen()

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = Block.new(chunk).tryGet()

      manifest.add(blk.cid)
      if not (await store.putBlock(blk)):
        raise newException(CatchableError, "Unable to store block " & $blk.cid)

  test "Test setup":
    let
      (tau, authenticators) = await setupPor(
        StoreStream.new(store, manifest),
        ssk,
        SectorsPerBlock)

    # echo "Auth: ", authenticators
    # echo "Tau: ", tau

    let q = generateQuery(tau, QueryLen)
    # echo "Generated!" , " q:", q

    let
      (mu, sigma) = await generateProof(
        StoreStream.new(store, manifest),
        q,
        authenticators,
        SectorsPerBlock)

    # echo " mu:", mu
    # echo " sigma:", sigma
    check verifyProof(spk, tau, q, mu, sigma)
