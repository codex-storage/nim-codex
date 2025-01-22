import std/httpclient
import std/sequtils
import std/strformat
from pkg/libp2p import `==`, `$`, Cid
import pkg/codex/units
import pkg/codex/manifest
import ./twonodes
import ../examples
import ../codex/examples
import ../codex/slots/helpers
import json

twonodessuite "REST API":
  test "nodes can print their peer information", twoNodesConfig:
    check !client1.info() != !client2.info()

  test "nodes can set chronicles log level", twoNodesConfig:
    client1.setLogLevel("DEBUG;TRACE:codex")

  test "node accepts file uploads", twoNodesConfig:
    let cid1 = client1.upload("some file contents").get
    let cid2 = client1.upload("some other contents").get

    check cid1 != cid2

  test "node shows used and available space", twoNodesConfig:
    discard client1.upload("some file contents").get
    let totalSize = 12.u256
    let minPricePerBytePerSecond = 1.u256
    let totalCollateral = totalSize * minPricePerBytePerSecond
    discard client1.postAvailability(
      totalSize = totalSize,
      duration = 2.u256,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = totalCollateral,
    ).get
    let space = client1.space().tryGet()
    check:
      space.totalBlocks == 2
      space.quotaMaxBytes == 8589934592.NBytes
      space.quotaUsedBytes == 65592.NBytes
      space.quotaReservedBytes == 12.NBytes

  test "node lists local files", twoNodesConfig:
    let content1 = "some file contents"
    let content2 = "some other contents"

    let cid1 = client1.upload(content1).get
    let cid2 = client1.upload(content2).get
    let list = client1.list().get

    check:
      [cid1, cid2].allIt(it in list.content.mapIt(it.cid))

  test "request storage fails for datasets that are too small", twoNodesConfig:
    let cid = client1.upload("some file contents").get
    let response = client1.requestStorageRaw(
      cid,
      duration = 10.u256,
      pricePerBytePerSecond = 1.u256,
      proofProbability = 3.u256,
      collateralPerByte = 1.u256,
      expiry = 9,
    )

    check:
      response.status == "400 Bad Request"
      response.body ==
        "Dataset too small for erasure parameters, need at least " &
        $(2 * DefaultBlockSize.int) & " bytes"

  test "request storage succeeds for sufficiently sized datasets", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let response = client1.requestStorageRaw(
      cid,
      duration = 10.u256,
      pricePerBytePerSecond = 1.u256,
      proofProbability = 3.u256,
      collateralPerByte = 1.u256,
      expiry = 9,
    )

    check:
      response.status == "200 OK"

  test "request storage fails if tolerance is zero", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = client1.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Tolerance needs to be bigger then zero"

  test "request storage fails if duration exceeds limit", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = (31 * 24 * 60 * 60).u256
      # 31 days TODO: this should not be hardcoded, but waits for https://github.com/codex-storage/nim-codex/issues/1056
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 2
    let pricePerBytePerSecond = 1.u256

    var responseBefore = client1.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == "400 Bad Request"
    check "Duration exceeds limit of" in responseBefore.body

  test "request storage fails if nodes and tolerance aren't correct", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateralPerByte = 1.u256
    let ecParams = @[(1, 1), (2, 1), (3, 2), (3, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body ==
        "Invalid parameters: parameters must satify `1 < (nodes - tolerance) ≥ tolerance`"

  test "request storage fails if tolerance > nodes (underflow protection)",
    twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.u256
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateralPerByte = 1.u256
    let ecParams = @[(0, 1), (1, 2), (2, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = client1.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )

      check responseBefore.status == "400 Bad Request"
      check responseBefore.body ==
        "Invalid parameters: `tolerance` cannot be greater than `nodes`"

  for ecParams in @[
    (minBlocks: 2, nodes: 3, tolerance: 1), (minBlocks: 3, nodes: 5, tolerance: 2)
  ]:
    let (minBlocks, nodes, tolerance) = ecParams
    test "request storage succeeds if nodes and tolerance within range " &
      fmt"({minBlocks=}, {nodes=}, {tolerance=})", twoNodesConfig:
      let data = await RandomChunker.example(blocks = minBlocks)
      let cid = client1.upload(data).get
      let duration = 100.u256
      let pricePerBytePerSecond = 1.u256
      let proofProbability = 3.u256
      let expiry = 30.uint
      let collateralPerByte = 1.u256

      var responseBefore = client1.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )

      check responseBefore.status == "200 OK"

  test "node accepts file uploads with content type", twoNodesConfig:
    let headers = newHttpHeaders({"Content-Type": "text/plain"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "node accepts file uploads with content disposition", twoNodesConfig:
    let headers =
      newHttpHeaders({"Content-Disposition": "attachment; filename=\"example.txt\""})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "node accepts file uploads with content disposition without filename",
    twoNodesConfig:
    let headers = newHttpHeaders({"Content-Disposition": "attachment"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "200 OK"
    check response.body != ""

  test "upload fails if content disposition contains bad filename", twoNodesConfig:
    let headers =
      newHttpHeaders({"Content-Disposition": "attachment; filename=\"exam*ple.txt\""})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The filename is not valid."

  test "upload fails if content type is invalid", twoNodesConfig:
    let headers = newHttpHeaders({"Content-Type": "hello/world"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The MIME type 'hello/world' is not valid."

  test "node retrieve the metadata", twoNodesConfig:
    let headers = newHttpHeaders(
      {
        "Content-Type": "text/plain",
        "Content-Disposition": "attachment; filename=\"example.txt\""
      }
    )
    let uploadResponse = client1.uploadRaw("some file contents", headers)
    let cid = uploadResponse.body
    let listResponse = client1.listRaw()

    let jsonData = parseJson(listResponse.body)

    check jsonData.hasKey("content") == true

    let content = jsonData["content"][0]

    check content.hasKey("manifest") == true

    let manifest = content["manifest"]

    check manifest.hasKey("filename") == true
    check manifest["filename"].getStr() == "example.txt"
    check manifest.hasKey("mimetype") == true
    check manifest["mimetype"].getStr() == "text/plain"

  test "node set the headers when for download", twoNodesConfig:
    let headers = newHttpHeaders(
      {
        "Content-Disposition": "attachment; filename=\"example.txt\"",
        "Content-Type": "text/plain"
      }
    )

    let uploadResponse = client1.uploadRaw("some file contents", headers)
    let cid = uploadResponse.body

    check uploadResponse.status == "200 OK"

    let response = client1.downloadRaw(cid)

    check response.status == "200 OK"
    check response.headers.hasKey("Content-Type") == true
    check response.headers["Content-Type"] == "text/plain"
    check response.headers.hasKey("Content-Disposition") == true
    check response.headers["Content-Disposition"] ==
      "attachment; filename=\"example.txt\""

    let local = true
    let localResponse = client1.downloadRaw(cid, local)

    check localResponse.status == "200 OK"
    check localResponse.headers.hasKey("Content-Type") == true
    check localResponse.headers["Content-Type"] == "text/plain"
    check localResponse.headers.hasKey("Content-Disposition") == true
    check localResponse.headers["Content-Disposition"] ==
      "attachment; filename=\"example.txt\""

  test "should delete a dataset when requested", twoNodesConfig:
    let cid = client1.upload("some file contents").get

    var response = client1.downloadRaw($cid, local = true)
    check response.body == "some file contents"

    client1.delete(cid).get

    response = client1.downloadRaw($cid, local = true)
    check response.status == "404 Not Found"

  test "should return 200 when attempting delete of non-existing block", twoNodesConfig:
    let response = client1.deleteRaw($(Cid.example()))
    check response.status == "204 No Content"

  test "should return 200 when attempting delete of non-existing dataset",
    twoNodesConfig:
    let cid = Manifest.example().makeManifestBlock().get.cid
    let response = client1.deleteRaw($cid)
    check response.status == "204 No Content"
