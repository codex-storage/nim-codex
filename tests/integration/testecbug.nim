from pkg/libp2p import Cid, init
import ../examples
import ./marketplacesuite
import ./nodeconfigs
import ./hardhatconfig

marketplacesuite "Bug #821 - node crashes during erasure coding":
  test "should be able to create storage request and download dataset",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug() # uncomment to enable console log output.debug()
        # .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        # .withLogTopics("node", "erasure", "marketplace")
        .some,
      providers: CodexConfigs.init(nodes = 0).some,
    ):
    let
      pricePerBytePerSecond = 1.u256
      duration = 20.periods
      collateralPerByte = 1.u256
      expiry = 10.periods
      data = await RandomChunker.example(blocks = 8)
      client = clients()[0]
      clientApi = client.client

    let cid = (await clientApi.upload(data)).get

    var requestId = none RequestId
    proc onStorageRequested(eventResult: ?!StorageRequested) =
      assert not eventResult.isErr
      requestId = some (!eventResult).requestId

    let subscription = await marketplace.subscribe(StorageRequested, onStorageRequested)

    # client requests storage but requires multiple slots to host the content
    let id = await clientApi.requestStorage(
      cid,
      duration = duration,
      pricePerBytePerSecond = pricePerBytePerSecond,
      expiry = expiry,
      collateralPerByte = collateralPerByte,
      nodes = 3,
      tolerance = 1,
    )

    check eventually(requestId.isSome, timeout = expiry.int * 1000)

    let
      request = await marketplace.getRequest(requestId.get)
      cidFromRequest = request.content.cid
      downloaded = await clientApi.downloadBytes(cidFromRequest, local = true)

    check downloaded.isOk
    check downloaded.get.toHex == data.toHex

    await subscription.unsubscribe()
