import std/sequtils
from pkg/libp2p import `==`
import pkg/codex/units
import ./twonodes

twonodessuite "REST API", debug1 = false, debug2 = false:

  test "nodes can print their peer information":
    check !client1.info() != !client2.info()

  test "nodes can set chronicles log level":
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads":
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get
    check cid1 != cid2

  test "node shows used and available space":
    discard client1.upload("some file contents").get
    discard client1.postAvailability(totalSize=12.u256, duration=2.u256, minPrice=3.u256, maxCollateral=4.u256).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2
      space.quotaMaxBytes == 8589934592.NBytes
      space.quotaUsedBytes == 65592.NBytes
      space.quotaReservedBytes == 12.NBytes

  test "node lists local files":
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client1.upload(content2).get
    let list = client1.list().get

    check:
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))
