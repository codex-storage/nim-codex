import std/unittest
import std/sequtils
import std/tables

import pkg/questionable/results
import pkg/stew/byteutils
import pkg/nimcrypto/sha2

import pkg/codex/merkletree
import ../helpers

checksuite "merkletree":
  const data =
    [
      "0123456789012345678901234567890123456789".toBytes,
      "1234567890123456789012345678901234567890".toBytes,
      "2345678901234567890123456789012345678901".toBytes,
      "3456789012345678901234567890123456789012".toBytes,
      "4567890123456789012345678901234567890123".toBytes,
      "5678901234567890123456789012345678901234".toBytes,
      "6789012345678901234567890123456789012345".toBytes,
      "7890123456789012345678901234567890123456".toBytes,
      "8901234567890123456789012345678901234567".toBytes,
      "9012345678901234567890123456789012345678".toBytes,
    ]

  const sha256 = multiCodec("sha2-256")
  const sha512 = multiCodec("sha2-512")

  proc combine(a, b: MultiHash, codec: MultiCodec = sha256): MultiHash =
    var buf = newSeq[byte](a.size + b.size)
    copyMem(addr buf[0], unsafeAddr a.data.buffer[a.dpos], a.size)
    copyMem(addr buf[a.size], unsafeAddr b.data.buffer[b.dpos], b.size)
    return MultiHash.digest($codec, buf).tryGet()

  var zeroHash: MultiHash
  var oneHash: MultiHash

  var expectedLeaves: array[data.len, MultiHash]
  var builder: MerkleTreeBuilder

  setup:
    for i in 0..<data.len:
      expectedLeaves[i] = MultiHash.digest($sha256, data[i]).tryGet()
    
    builder = MerkleTreeBuilder.init(sha256).tryGet()
    var zero: array[32, byte]
    var one: array[32, byte]
    one[^1] = 0x01
    zeroHash = MultiHash.init($sha256, zero).tryGet()
    oneHash = MultiHash.init($sha256, one).tryGet()

  test "tree with one leaf has expected structure":
    builder.addDataBlock(data[0]).tryGet()

    let tree = builder.build().tryGet()

    check:
      tree.leaves == expectedLeaves[0..0]
      tree.root == expectedLeaves[0]
      tree.len == 1

  test "tree with two leaves has expected structure":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()

    let tree = builder.build().tryGet()

    let expectedRoot = combine(expectedLeaves[0], expectedLeaves[1])

    check:
      tree.leaves == expectedLeaves[0..1]
      tree.len == 3
      tree.root == expectedRoot

  test "tree with three leaves has expected structure":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()

    let tree = builder.build().tryGet()

    let
      expectedRoot = combine(
        combine(expectedLeaves[0], expectedLeaves[1]), 
        combine(expectedLeaves[2], zeroHash)
      )

    check:
      tree.leaves == expectedLeaves[0..2]
      tree.len == 6
      tree.root == expectedRoot

  test "tree with nine leaves has expected structure":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()
    builder.addDataBlock(data[3]).tryGet()
    builder.addDataBlock(data[4]).tryGet()
    builder.addDataBlock(data[5]).tryGet()
    builder.addDataBlock(data[6]).tryGet()
    builder.addDataBlock(data[7]).tryGet()
    builder.addDataBlock(data[8]).tryGet()

    let tree = builder.build().tryGet()

    let
      expectedRoot = combine(
        combine(
          combine(
            combine(expectedLeaves[0], expectedLeaves[1]),
            combine(expectedLeaves[2], expectedLeaves[3]), 
          ),
          combine( 
            combine(expectedLeaves[4], expectedLeaves[5]), 
            combine(expectedLeaves[6], expectedLeaves[7])
          )
        ),
        combine(
          combine( 
            combine(expectedLeaves[8], zeroHash),
            oneHash
          ),
          oneHash
        )
      )

    check:
      tree.leaves == expectedLeaves[0..8]
      tree.len == 20
      tree.root == expectedRoot

  test "tree with two leaves provides expected proofs":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()

    let tree = builder.build().tryGet()

    let expectedProofs = [
      MerkleProof.init(0, @[expectedLeaves[1]]).tryGet(),
      MerkleProof.init(1, @[expectedLeaves[0]]).tryGet(),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
  
  test "tree with three leaves provides expected proofs":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()

    let tree = builder.build().tryGet()

    let expectedProofs = [
      MerkleProof.init(0, @[expectedLeaves[1], combine(expectedLeaves[2], zeroHash)]).tryGet(),
      MerkleProof.init(1, @[expectedLeaves[0], combine(expectedLeaves[2], zeroHash)]).tryGet(),
      MerkleProof.init(2, @[zeroHash, combine(expectedLeaves[0], expectedLeaves[1])]).tryGet(),
    ]

    check:
      tree.getProof(0).tryGet() == expectedProofs[0]
      tree.getProof(1).tryGet() == expectedProofs[1]
      tree.getProof(2).tryGet() == expectedProofs[2]

  test "tree with nine leaves provides expected proofs":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()
    builder.addDataBlock(data[3]).tryGet()
    builder.addDataBlock(data[4]).tryGet()
    builder.addDataBlock(data[5]).tryGet()
    builder.addDataBlock(data[6]).tryGet()
    builder.addDataBlock(data[7]).tryGet()
    builder.addDataBlock(data[8]).tryGet()

    let tree = builder.build().tryGet()

    let expectedProofs = {
      4: 
        MerkleProof.init(4, @[
          expectedLeaves[5], 
          combine(expectedLeaves[6], expectedLeaves[7]), 
          combine(
              combine(expectedLeaves[0], expectedLeaves[1]),
              combine(expectedLeaves[2], expectedLeaves[3]), 
          ),
          combine(
            combine( 
              combine(expectedLeaves[8], zeroHash),
              oneHash
            ),
            oneHash
          )
        ]).tryGet(),
      8: 
        MerkleProof.init(8, @[
          zeroHash, 
          oneHash,
          oneHash,
          combine(
            combine(
              combine(expectedLeaves[0], expectedLeaves[1]),
              combine(expectedLeaves[2], expectedLeaves[3]), 
            ),
            combine( 
              combine(expectedLeaves[4], expectedLeaves[5]), 
              combine(expectedLeaves[6], expectedLeaves[7])
            )
          )
        ]).tryGet(),
    }.newTable

    check:
      tree.getProof(4).tryGet() == expectedProofs[4]
      tree.getProof(8).tryGet() == expectedProofs[8]

  test "getProof fails for index out of bounds":
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()

    let tree = builder.build().tryGet()

    check:
      isErr(tree.getProof(4))
