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
  var config = CodexConfigs.init(nodes = 1).configs[0]
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

  let client = node.client()

  test "should return 422 when attempting delete of non-existing dataset":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == 422
    check (await responseBefore.body) == "Tolerance needs to be bigger then zero"

  test "request storage fails for datasets that are too small":
    let cid = (await client.upload("some file contents")).get
    let response = (
      await client.requestStorageRaw(
        cid,
        duration = 10.uint64,
        pricePerBytePerSecond = 1.u256,
        proofProbability = 3.u256,
        collateralPerByte = 1.u256,
        expiry = 9.uint64,
      )
    )

    check:
      response.status == 422
      (await response.body) ==
        "Dataset too small for erasure parameters, need at least " &
        $(2 * DefaultBlockSize.int) & " bytes"

  test "request storage fails if nodes and tolerance aren't correct":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let ecParams = @[(1, 1), (2, 1), (3, 2), (3, 3)]

    for ecParam in ecParams:
      let (nodes, tolerance) = ecParam

      var responseBefore = (
        await client.requestStorageRaw(
          cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
          expiry, nodes.uint, tolerance.uint,
        )
      )

      check responseBefore.status == 422
      check (await responseBefore.body) ==
        "Invalid parameters: parameters must satify `1 < (nodes - tolerance) ≥ tolerance`"

  test "request storage fails if tolerance > nodes (underflow protection)":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = (
      await client.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )
    )

    check responseBefore.status == 422
    check (await responseBefore.body) == "Tolerance needs to be bigger then zero"

  test "upload fails if content disposition contains bad filename":
    let headers = @[("Content-Disposition", "attachment; filename=\"exam*ple.txt\"")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The filename is not valid."

  test "upload fails if content type is invalid":
    let headers = @[("Content-Type", "hello/world")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The MIME type 'hello/world' is not valid."

  test "updating non-existing availability":
    let nonExistingResponse = await client.patchAvailabilityRaw(
      AvailabilityId.example,
      duration = 100.uint64.some,
      minPricePerBytePerSecond = 2.u256.some,
      totalCollateral = 200.u256.some,
    )
    check nonExistingResponse.status == 404

  test "updating availability - freeSize is not allowed to be changed":
    let availability = (
      await client.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get
    let freeSizeResponse =
      await client.patchAvailabilityRaw(availability.id, freeSize = 110000.uint64.some)
    check freeSizeResponse.status == 422
    check "not allowed" in (await freeSizeResponse.body)

  test "creating availability above the node quota returns 422":
    let response = await client.postAvailabilityRaw(
      totalSize = 24000000000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == 422
    check (await response.body) == "Not enough storage quota"

  test "updating availability above the node quota returns 422":
    let availability = (
      await client.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get
    let response = await client.patchAvailabilityRaw(
      availability.id, totalSize = 24000000000.uint64.some
    )

    check response.status == 422
    check (await response.body) == "Not enough storage quota"

  test "creating availability when total size is zero returns 422":
    let response = await client.postAvailabilityRaw(
      totalSize = 0.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == 422
    check (await response.body) == "Total size must be larger then zero"

  test "updating availability when total size is zero returns 422":
    let availability = (
      await client.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get
    let response =
      await client.patchAvailabilityRaw(availability.id, totalSize = 0.uint64.some)

    check response.status == 422
    check (await response.body) == "Total size must be larger then zero"

  test "creating availability when total size is negative returns 422":
    let json =
      %*{
        "totalSize": "-1",
        "duration": "200",
        "minPricePerBytePerSecond": "3",
        "totalCollateral": "300",
      }
    let response = await client.post(client.buildUrl("/sales/availability"), $json)

    check response.status == 400
    check (await response.body) == "Parsed integer outside of valid range"

  test "updating availability when total size is negative returns 422":
    let availability = (
      await client.postAvailability(
        totalSize = 140000.uint64,
        duration = 200.uint64,
        minPricePerBytePerSecond = 3.u256,
        totalCollateral = 300.u256,
      )
    ).get

    let json = %*{"totalSize": "-1"}
    let response = await client.patch(
      client.buildUrl("/sales/availability/") & $availability.id, $json
    )

    check response.status == 400
    check (await response.body) == "Parsed integer outside of valid range"

  test "request storage fails if tolerance is zero":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 0

    var responseBefore = (
      await client.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )
    )

    check responseBefore.status == 422
    check (await responseBefore.body) == "Tolerance needs to be bigger then zero"

  test "request storage fails if duration exceeds limit":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = (31 * 24 * 60 * 60).uint64
      # 31 days TODO: this should not be hardcoded, but waits for https://github.com/codex-storage/nim-codex/issues/1056
    let proofProbability = 3.u256
    let expiry = 30.uint
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 2
    let pricePerBytePerSecond = 1.u256

    var responseBefore = (
      await client.requestStorageRaw(
        cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte,
        expiry, nodes.uint, tolerance.uint,
      )
    )

    check responseBefore.status == 422
    check "Duration exceeds limit of" in (await responseBefore.body)

  test "request storage fails if expiry is zero":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 0.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 1

    var responseBefore = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == 422
    check (await responseBefore.body) ==
      "Expiry must be greater than zero and less than the request's duration"

  test "request storage fails if proof probability is zero":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 0.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 1

    var responseBefore = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == 422
    check (await responseBefore.body) == "Proof probability must be greater than zero"

  test "request storage fails if price per byte per second is zero":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 0.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 1.u256
    let nodes = 3
    let tolerance = 1

    var responseBefore = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == 422
    check (await responseBefore.body) ==
      "Price per byte per second must be greater than zero"

  test "request storage fails if collareral per byte is zero":
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = 100.uint64
    let pricePerBytePerSecond = 1.u256
    let proofProbability = 3.u256
    let expiry = 30.uint64
    let collateralPerByte = 0.u256
    let nodes = 3
    let tolerance = 1

    var responseBefore = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes.uint, tolerance.uint,
    )

    check responseBefore.status == 422
    check (await responseBefore.body) == "Collateral per byte must be greater than zero"

  test "creating availability fails when until is negative":
    let totalSize = 12.uint64
    let minPricePerBytePerSecond = 1.u256
    let totalCollateral = totalSize.u256 * minPricePerBytePerSecond
    let response = await client.postAvailabilityRaw(
      totalSize = totalSize,
      duration = 2.uint64,
      minPricePerBytePerSecond = minPricePerBytePerSecond,
      totalCollateral = totalCollateral,
      until = -1.SecondsSince1970.some,
    )

    check:
      response.status == 422
      (await response.body) == "Cannot set until to a negative value"

  waitFor node.stop()
  node.removeDataDir()
