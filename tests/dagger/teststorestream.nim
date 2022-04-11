import pkg/chronos
import pkg/asynctest
import pkg/libp2p
import pkg/questionable/results

import ./helpers

import pkg/dagger/streams
import pkg/dagger/stores
import pkg/dagger/manifest

suite "StoreStream":
  var
    manifest: Manifest
    store: BlockStore
    stream: StoreStream

  let
    data = [
      [byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
      [byte 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
      [byte 20, 21, 22, 23, 24, 25, 26, 27, 28, 29],
      [byte 30, 31, 32, 33, 34, 35, 36, 37, 38, 39],
      [byte 40, 41, 42, 43, 44, 45, 46, 47, 48, 49],
      [byte 50, 51, 52, 53, 54, 55, 56, 57, 58, 59],
      [byte 60, 61, 62, 63, 64, 65, 66, 67, 68, 69],
      [byte 70, 71, 72, 73, 74, 75, 76, 77, 78, 79],
      [byte 80, 81, 82, 83, 84, 85, 86, 87, 88, 89],
      [byte 90, 91, 92, 93, 94, 95, 96, 97, 98, 99],
    ]

  setup:
    store = CacheStore.new()
    manifest = Manifest.new(blockSize = 10).tryGet()
    stream = StoreStream.new(store, manifest)

    for d in data:
      let
        blk = Block.new(d).tryGet()

      manifest.add(blk.cid)
      if not (await store.putBlock(blk)):
        raise newException(CatchableError, "Unable to store block " & $blk.cid)

  test "Read all blocks < blockSize":
    var
      buf = newSeq[byte](8)

    while not stream.atEof:
      let
        read = (await stream.readOnce(addr buf[0], buf.len))

      if stream.atEof.not:
        check read == 8
      else:
        check read == 4

  test "Read all blocks == blockSize":
    var
      buf = newSeq[byte](10)

    while not stream.atEof:
      let
        read = (await stream.readOnce(addr buf[0], buf.len))

      check read == 10

  test "Read all blocks > blockSize":
    var
      buf = newSeq[byte](11)

    while not stream.atEof:
      let
        read = (await stream.readOnce(addr buf[0], buf.len))

      if stream.atEof.not:
        check read == 11
      else:
        check read == 1

  test "Read exact bytes within block boundary":
    var
      buf = newSeq[byte](5)

    await stream.readExactly(addr buf[0], 5)
    check buf == [byte 0, 1, 2, 3, 4]

  test "Read exact bytes outside of block boundary":
    var
      buf = newSeq[byte](15)

    await stream.readExactly(addr buf[0], 15)
    check buf == [byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
