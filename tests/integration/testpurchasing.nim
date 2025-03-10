import std/options
import std/httpclient
import pkg/codex/rng
import ./twonodes
import ../contracts/time
import ../examples

twonodessuite "Purchasing":
  test "node handles storage request", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client1.upload(data)).get
    let id1 = (
      await client1.requestStorage(
        cid,
        duration = 100.uint64,
        pricePerBytePerSecond = 1.u256,
        proofProbability = 3.u256,
        expiry = 10.uint64,
        collateralPerByte = 1.u256,
      )
    ).get
    let id2 = (
      await client1.requestStorage(
        cid,
        duration = 400.uint64,
        pricePerBytePerSecond = 2.u256,
        proofProbability = 6.u256,
        expiry = 10.uint64,
        collateralPerByte = 2.u256,
      )
    ).get
    check id1 != id2

  test "node retrieves purchase status", twoNodesConfig:
    # get one contiguous chunk
    let rng = rng.Rng.instance()
    let chunker = RandomChunker.new(
      rng, size = DefaultBlockSize * 2, chunkSize = DefaultBlockSize * 2
    )
    let data = await chunker.getBytes()
    let cid = (await client1.upload(byteutils.toHex(data))).get
    let id = (
      await client1.requestStorage(
        cid,
        duration = 100.uint64,
        pricePerBytePerSecond = 1.u256,
        proofProbability = 3.u256,
        expiry = 30.uint64,
        collateralPerByte = 1.u256,
        nodes = 3,
        tolerance = 1,
      )
    ).get

    let request = (await client1.getPurchase(id)).get.request.get

    check request.content.cid.data.buffer.len > 0
    check request.ask.duration == 100.uint64
    check request.ask.pricePerBytePerSecond == 1.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == 30.uint64
    check request.ask.collateralPerByte == 1.u256
    check request.ask.slots == 3'u64
    check request.ask.maxSlotLoss == 1'u64

  # TODO: We currently do not support encoding single chunks
  # test "node retrieves purchase status with 1 chunk", twoNodesConfig:
  #   let cid = client1.upload("some file contents").get
  #   let id = client1.requestStorage(
  #     cid, duration=1.u256, pricePerBytePerSecond=1.u256,
  #     proofProbability=3.u256, expiry=30, collateralPerByte=1.u256,
  #     nodes=2, tolerance=1).get
  #   let request = client1.getPurchase(id).get.request.get
  #   check request.ask.duration == 1.u256
  #   check request.ask.pricePerBytePerSecond == 1.u256
  #   check request.ask.proofProbability == 3.u256
  #   check request.expiry == 30
  #   check request.ask.collateralPerByte == 1.u256
  #   check request.ask.slots == 3'u64
  #   check request.ask.maxSlotLoss == 1'u64

  test "node remembers purchase status after restart", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client1.upload(data)).get
    let id = (
      await client1.requestStorage(
        cid,
        duration = 10 * 60.uint64,
        pricePerBytePerSecond = 1.u256,
        proofProbability = 3.u256,
        expiry = 5 * 60.uint64,
        collateralPerByte = 1.u256,
        nodes = 3.uint,
        tolerance = 1.uint,
      )
    ).get
    check eventually(
      await client1.purchaseStateIs(id, "submitted"), timeout = 3 * 60 * 1000
    )

    await node1.restart()

    check eventually(
      await client1.purchaseStateIs(id, "submitted"), timeout = 3 * 60 * 1000
    )
    let request = (await client1.getPurchase(id)).get.request.get
    check request.ask.duration == (10 * 60).uint64
    check request.ask.pricePerBytePerSecond == 1.u256
    check request.ask.proofProbability == 3.u256
    check request.expiry == (5 * 60).uint64
    check request.ask.collateralPerByte == 1.u256
    check request.ask.slots == 3'u64
    check request.ask.maxSlotLoss == 1'u64

  test "node requires expiry and its value to be in future", twoNodesConfig:
    let data = await RandomChunker.example(blocks = 2)
    let cid = (await client1.upload(data)).get

    let responseMissing = await client1.requestStorageRaw(
      cid,
      duration = 1.uint64,
      pricePerBytePerSecond = 1.u256,
      proofProbability = 3.u256,
      collateralPerByte = 1.u256,
    )
    check responseMissing.status == 422
    check (await responseMissing.body) ==
      "Expiry must be greater than zero and less than the request's duration"

    let responseBefore = await client1.requestStorageRaw(
      cid,
      duration = 10.uint64,
      pricePerBytePerSecond = 1.u256,
      proofProbability = 3.u256,
      collateralPerByte = 1.u256,
      expiry = 10.uint64,
    )
    check responseBefore.status == 422
    check "Expiry must be greater than zero and less than the request's duration" in
      (await responseBefore.body)
