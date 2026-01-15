import std/times
import pkg/ethers
import pkg/codex/conf
import pkg/codex/contracts
import ../../asynctest
import ../../checktest
import ../../examples
import ../../codex/examples
import ../codexconfig
import ../codexclient
import ../multinodes

multinodesuite "Rest API validation":
  let config = NodeConfigs(clients: CodexConfigs.init(nodes = 1).some)
  var client: CodexClient

  setup:
    client = clients()[0].client

  test "should return 422 when attempting delete of non-existing dataset", config:
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

  test "request storage fails for datasets that are too small", config:
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

  test "request storage fails if nodes and tolerance aren't correct", config:
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

  test "request storage fails if tolerance > nodes (underflow protection)", config:
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

  test "upload fails if content disposition contains bad filename", config:
    let headers = @[("Content-Disposition", "attachment; filename=\"exam*ple.txt\"")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The filename is not valid."

  test "upload fails if content type is invalid", config:
    let headers = @[("Content-Type", "hello/world")]
    let response = await client.uploadRaw("some file contents", headers)

    check response.status == 422
    check (await response.body) == "The MIME type 'hello/world' is not valid."

  test "updating non-existing availability", config:
    let nonExistingResponse = await client.patchAvailabilityRaw(
      AvailabilityId.example,
      duration = 100.uint64.some,
      minPricePerBytePerSecond = 2.u256.some,
      totalCollateral = 200.u256.some,
    )
    check nonExistingResponse.status == 404

  test "updating availability - freeSize is not allowed to be changed", config:
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

  test "creating availability above the node quota returns 422", config:
    let response = await client.postAvailabilityRaw(
      totalSize = 24000000000.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == 422
    check (await response.body) == "Not enough storage quota"

  test "updating availability above the node quota returns 422", config:
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

  test "creating availability when total size is zero returns 422", config:
    let response = await client.postAvailabilityRaw(
      totalSize = 0.uint64,
      duration = 200.uint64,
      minPricePerBytePerSecond = 3.u256,
      totalCollateral = 300.u256,
    )

    check response.status == 422
    check (await response.body) == "Total size must be larger then zero"

  test "updating availability when total size is zero returns 422", config:
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

  test "creating availability when total size is negative returns 422", config:
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

  test "updating availability when total size is negative returns 422", config:
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

  test "request storage fails if tolerance is zero", config:
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

  test "request storage fails if duration exceeds limit", config:
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client.upload(data)).get
    let duration = (31 * 24 * 60 * 60).uint64
      # 31 days TODO: this should not be hardcoded, but waits for https://github.com/logos-storage/logos-storage-nim/issues/1056
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

  test "request storage fails if expiry is zero", config:
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

  test "request storage fails if proof probability is zero", config:
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

  test "request storage fails if price per byte per second is zero", config:
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

  test "request storage fails if collareral per byte is zero", config:
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

  test "creating availability fails when until is negative", config:
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

  test "creating availability fails when duration is zero", config:
    let response = await client.postAvailabilityRaw(
      totalSize = 12.uint64,
      duration = 0.uint64,
      minPricePerBytePerSecond = 1.u256,
      totalCollateral = 22.u256,
      until = -1.SecondsSince1970.some,
    )

    check:
      response.status == 422
      (await response.body) == "duration must be larger then zero"

  test "creating availability fails when minPricePerBytePerSecond is zero", config:
    let response = await client.postAvailabilityRaw(
      totalSize = 12.uint64,
      duration = 1.uint64,
      minPricePerBytePerSecond = 0.u256,
      totalCollateral = 22.u256,
      until = -1.SecondsSince1970.some,
    )

    check:
      response.status == 422
      (await response.body) == "minPricePerBytePerSecond must be larger then zero"

  test "creating availability fails when totalCollateral is zero", config:
    let response = await client.postAvailabilityRaw(
      totalSize = 12.uint64,
      duration = 1.uint64,
      minPricePerBytePerSecond = 2.u256,
      totalCollateral = 0.u256,
      until = -1.SecondsSince1970.some,
    )

    check:
      response.status == 422
      (await response.body) == "totalCollateral must be larger then zero"

  test "has block returns error 400 when the cid is invalid", config:
    let response = await client.hasBlockRaw("invalid-cid")

    check:
      response.status == 400
      (await response.body) == "Incorrect Cid"
