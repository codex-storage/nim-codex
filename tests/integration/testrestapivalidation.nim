import std/httpclient
import std/times
import pkg/ethers
import pkg/codex/manifest
import pkg/codex/conf
import pkg/codex/contracts
from pkg/codex/stores/repostore/types import DefaultQuotaBytes
import ../asynctest
import ../checktest
import ../examples
import ../codex/examples
import ./codexconfig
import ./codexprocess

from ./multinodes import Role, getTempDirName, jsonRpcProviderUrl, nextFreePort

# This suite allows to run fast the basic rest api validation.
# It starts only one node for all the checks in order to speed up 
# the execution.
asyncchecksuite "Rest API validation":
  var node: CodexProcess
  var config = CodexConfigs.init(nodes = 1).debug().configs[0]
  let starttime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  let nodexIdx = 0
  let datadir = getTempDirName(starttime, Role.Client, nodexIdx)

  config.addCliOption("--api-port", $(waitFor nextFreePort(8081)))
  config.addCliOption("--data-dir", datadir)
  config.addCliOption("--nat", "none")
  config.addCliOption("--listen-addrs", "/ip4/127.0.0.1/tcp/0")
  config.addCliOption("--disc-port", $(waitFor nextFreePort(8081)))
  config.addCliOption(StartUpCmd.persistence, "--eth-provider", jsonRpcProviderUrl)
  config.addCliOption(StartUpCmd.persistence, "--eth-account", $EthAddress.example)

  node =
    waitFor CodexProcess.startNode(config.cliArgs, config.debugEnabled, $Role.Client)

  waitFor node.waitUntilStarted()

  let client1 = node.client()

  test "should return 400 when attempting delete of non-existing dataset":
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = client1.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == "400 Bad Request"
    check responseBefore.body == "Tolerance needs to be bigger then zero"

  test "request storage fails for datasets that are too small":
    let cid = client1.upload("some file contents").get
    let response = client1.requestStorageRaw(
      cid,
      duration = 10.uint64,
      pricePerBytePerSecond = 1.u256,
      proofProbability = 3.u256,
      collateralPerByte = 1.u256,
      expiry = 9.uint64,
    )

    check:
      response.status == "400 Bad Request"
      response.body ==
        "Dataset too small for erasure parameters, need at least " &
        $(2 * DefaultBlockSize.int) & " bytes"

  test "request storage fails if nodes and tolerance aren't correct":
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
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

  test "request storage fails if tolerance > nodes (underflow protection)":
    let data = await RandomChunker.example(blocks = 2)
    let cid = client1.upload(data).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
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

  test "upload fails if content disposition contains bad filename":
    let headers =
      newHttpHeaders({"Content-Disposition": "attachment; filename=\"exam*ple.txt\""})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The filename is not valid."

  test "upload fails if content type is invalid":
    let headers = newHttpHeaders({"Content-Type": "hello/world"})
    let response = client1.uploadRaw("some file contents", headers)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The MIME type 'hello/world' is not valid."

  test "updating non-existing availability":
    let nonExistingResponse = client1.patchAvailabilityRaw(
      AvailabilityId.example,
      duration = 100.uint64.some,
      minPricePerBytePerSecond = 2.u256.some,
      totalCollateral = 200.u256.some,
    )
    check nonExistingResponse.status == "404 Not Found"

  test "updating availability - freeSize is not allowed to be changed":
    let availability = client1.postAvailability(
      totalSize = 140000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    ).get
    let freeSizeResponse =
      client1.patchAvailabilityRaw(availability.id, freeSize = 110000.uint64.some)
    check freeSizeResponse.status == "422 Unprocessable Entity"
    check "not allowed" in freeSizeResponse.body

  test "creating availability above the node quota returns 422":
    let response = client1.postAvailabilityRaw(
      totalSize = 24000000000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == "422 Unprocessable Entity"
    check response.body == "Not enough storage quota"

  test "updating availability above the node quota returns 422":
    let availability = client1.postAvailability(
      totalSize = 140000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    ).get
    let response =
      client1.patchAvailabilityRaw(availability.id, totalSize = 24000000000.uint64.some)

    check response.status == "422 Unprocessable Entity"
    check response.body == "Not enough storage quota"

  test "creating availability when total size is zero returns 422":
    let response = client1.postAvailabilityRaw(
      totalSize = 0.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == "422 Unprocessable Entity"
    check response.body == "Total size must be larger then zero"

  test "updating availability when total size is zero returns 422":
    let availability = client1.postAvailability(
      totalSize = 140000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    ).get
    let response =
      client1.patchAvailabilityRaw(availability.id, totalSize = 0.uint64.some)

    check response.status == "422 Unprocessable Entity"
    check response.body == "Total size must be larger then zero"

  test "creating availability when total size is negative returns 422":
    let response = client1.postAvailabilityRaw(
      totalSize = -1.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == "422 Unprocessable Entity"
    check response.body == "The values provided are out of range"

  test "updating availability when total size is negative returns 422":
    let availability = client1.postAvailability(
      totalSize = 140000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    ).get
    let response =
      client1.patchAvailabilityRaw(availability.id, totalSize = -1.uint64.some)

    check response.status == "422 Unprocessable Entity"
    check response.body == "The values provided are out of range"

  waitFor node.stop()
  node.removeDataDir()
