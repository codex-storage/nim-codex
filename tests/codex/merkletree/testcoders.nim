import std/unittest

import pkg/questionable/results
import pkg/stew/byteutils

import pkg/codex/merkletree
import ../helpers

checksuite "merkletree - coders":
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

  test "encoding and decoding a tree yields the same tree":
    var builder = MerkleTreeBuilder.init(multiCodec("sha2-256")).tryGet()
    builder.addDataBlock(data[0]).tryGet()
    builder.addDataBlock(data[1]).tryGet()
    builder.addDataBlock(data[2]).tryGet()
    builder.addDataBlock(data[3]).tryGet()
    builder.addDataBlock(data[4]).tryGet()
    builder.addDataBlock(data[5]).tryGet()
    builder.addDataBlock(data[6]).tryGet()
    builder.addDataBlock(data[7]).tryGet()
    builder.addDataBlock(data[8]).tryGet()
    builder.addDataBlock(data[9]).tryGet()

    let tree = builder.build().tryGet()
    let encodedBytes = tree.encode()
    echo "encode success, size " & $encodedBytes.len
    let decodedTree = MerkleTree.decode(encodedBytes).tryGet()

    check:
      tree == decodedTree
