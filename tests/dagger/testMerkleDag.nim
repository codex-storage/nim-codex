import std/unittest
import pkg/dagger/merkledag

suite "Merkle DAG":

  test "has a root hash":
    let dag1 = MerkleDag(data: @[1'u8, 2'u8, 3'u8])
    let dag2 = MerkleDag(data: @[4'u8, 5'u8, 6'u8])
    let dag3 = MerkleDag(data: @[4'u8, 5'u8, 6'u8])
    check dag1.rootHash != dag2.rootHash
    check dag2.rootHash == dag3.rootHash
