import std/importutils
import std/net
import std/sequtils
import std/strformat
from pkg/libp2p import `==`, `$`, Cid
import pkg/codex/units
import pkg/codex/manifest
import ../twonodes
import ../../examples
import ../../codex/examples
import ../../codex/slots/helpers
import json

twonodessuite "REST API":
  test "nodes can print their peer information", twoNodesConfig:
    check !(await client1.info()) != !(await client2.info())

  test "nodes can set chronicles log level", twoNodesConfig:
    await client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads", twoNodesConfig:
    let cid1 = (await client1.upload("some file contents")).get
    let cid2 = (await client1.upload("some other contents")).get

    check cid1 != cid2

  test "node lists local files", twoNodesConfig:
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = (await client1.upload(content1)).get
    let cid2 = (await client1.upload(content2)).get
    let list = (await client1.list()).get

    check:
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))

  test "node accepts file uploads with content type", twoNodesConfig:
    let headers = @[("Content-Type", "text/plain")]
    let response = await client1.uploadRaw("some file contents", headers)

    check response.status == 200
    check (await response.body) != ""

  test "node accepts file uploads with content disposition", twoNodesConfig:
    let headers = @[("Content-Disposition", "attachment; filename=\"example.txt\"")]
    let response = await client1.uploadRaw("some file contents", headers)

    check response.status == 200
    check (await response.body) != ""

  test "node accepts file uploads with content disposition without filename",
    twoNodesConfig:
    let headers = @[("Content-Disposition", "attachment")]
    let response = await client1.uploadRaw("some file contents", headers)

    check response.status == 200
    check (await response.body) != ""

  test "node retrieve the metadata", twoNodesConfig:
    let headers =
      @[
        ("Content-Type", "text/plain"),
        ("Content-Disposition", "attachment; filename=\"example.txt\""),
      ]
    let uploadResponse = await client1.uploadRaw("some file contents", headers)
    let cid = await uploadResponse.body
    let listResponse = await client1.listRaw()

    let jsonData = parseJson(await listResponse.body)

    check jsonData.hasKey("content") == true

    let content = jsonData["content"][0]

    check content.hasKey("manifest") == true

    let manifest = content["manifest"]

    check manifest.hasKey("filename") == true
    check manifest["filename"].getStr() == "example.txt"
    check manifest.hasKey("mimetype") == true
    check manifest["mimetype"].getStr() == "text/plain"

  test "node set the headers when for download", twoNodesConfig:
    let headers =
      @[
        ("Content-Disposition", "attachment; filename=\"example.txt\""),
        ("Content-Type", "text/plain"),
      ]

    let uploadResponse = await client1.uploadRaw("some file contents", headers)
    let cid = await uploadResponse.body

    check uploadResponse.status == 200

    let response = await client1.downloadRaw(cid)

    check response.status == 200
    check "Content-Type" in response.headers
    check response.headers.getString("Content-Type") == "text/plain"
    check "Content-Disposition" in response.headers
    check response.headers.getString("Content-Disposition") ==
      "attachment; filename=\"example.txt\""

    let local = true
    let localResponse = await client1.downloadRaw(cid, local)

    check localResponse.status == 200
    check "Content-Type" in localResponse.headers
    check localResponse.headers.getString("Content-Type") == "text/plain"
    check "Content-Disposition" in localResponse.headers
    check localResponse.headers.getString("Content-Disposition") ==
      "attachment; filename=\"example.txt\""

  test "should delete a dataset when requested", twoNodesConfig:
    let cid = (await client1.upload("some file contents")).get

    var response = await client1.downloadRaw($cid, local = true)
    check (await response.body) == "some file contents"

    (await client1.delete(cid)).get

    response = await client1.downloadRaw($cid, local = true)
    check response.status == 404

  test "should return 200 when attempting delete of non-existing block", twoNodesConfig:
    let response = await client1.deleteRaw($(Cid.example()))
    check response.status == 204

  test "should return 200 when attempting delete of non-existing dataset",
    twoNodesConfig:
    let cid = Manifest.example().makeManifestBlock().get.cid
    let response = await client1.deleteRaw($cid)
    check response.status == 204

  test "should not crash if the download stream is closed before download completes",
    twoNodesConfig:
    # FIXME this is not a good test. For some reason, to get this to fail, I have to
    #   store content that is several times the default stream buffer size, otherwise
    #   the test will succeed even when the bug is present. Since this is probably some
    #   setting that is internal to chronos, it might change in future versions,
    #   invalidating this test. Works on Chronos 4.0.3.

    let
      contents = repeat("b", DefaultStreamBufferSize * 10)
      cid = (await client1.upload(contents)).get
      response = await client1.downloadRaw($cid)

    let reader = response.getBodyReader()

    # Read 4 bytes from the stream just to make sure we actually
    # receive some data.
    check (bytesToString await reader.read(4)) == "bbbb"

    # Abruptly closes the stream (we have to dig all the way to the transport
    #   or Chronos will close things "nicely").
    response.connection.reader.tsource.close()

    let response2 = await client1.downloadRaw($cid)
    check (await response2.body) == contents

  test "should returns true when the block exists", twoNodesConfig:
    let cid = (await client2.upload("some file contents")).get

    var response = await client1.hasBlock(cid)
    check response.get() == false

    discard (await client1.download(cid)).get
    response = await client1.hasBlock(cid)
    check response.get() == false
