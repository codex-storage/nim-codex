import std/unittest
import pkg/libp2p
import pkg/dagger/merkledag

suite "Merkle DAG":

  test "has a content id":
    let dag1 = MerkleDag(data: @[1'u8, 2'u8, 3'u8])
    let dag2 = MerkleDag(data: @[4'u8, 5'u8, 6'u8])
    let dag3 = MerkleDag(data: @[4'u8, 5'u8, 6'u8])
    check dag1.rootId != dag2.rootId
    check dag2.rootId == dag3.rootId
