import std/unittest
import pkg/libp2p
import pkg/dagger/obj

suite "objects":

  test "have content ids":
    let dag1 = Object(data: @[1'u8, 2'u8, 3'u8])
    let dag2 = Object(data: @[4'u8, 5'u8, 6'u8])
    let dag3 = Object(data: @[4'u8, 5'u8, 6'u8])
    check dag1.cid != dag2.cid
    check dag2.cid == dag3.cid
