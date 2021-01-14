import std/unittest
import pkg/libp2p
import pkg/ipfs/ipfsobject

suite "IPFS Object":

  test "has a content id":
    let dag1 = IpfsObject(data: @[1'u8, 2'u8, 3'u8])
    let dag2 = IpfsObject(data: @[4'u8, 5'u8, 6'u8])
    let dag3 = IpfsObject(data: @[4'u8, 5'u8, 6'u8])
    check dag1.cid != dag2.cid
    check dag2.cid == dag3.cid
