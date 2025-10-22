from pkg/libp2p import Cid, init
import ../../examples
import ../marketplacesuite
import ../nodeconfigs
import ../hardhatconfig

marketplacesuite(name = "Bug #821 - node crashes during erasure coding"):
  test "should be able to create storage request and download dataset",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        # .debug() # uncomment to enable console log output.debug()
        .withLogFile()
        # uncomment to output log file to tests/integration/logs/<start_datetime> <suite_name>/<test_name>/<node_role>_<node_idx>.log
        .withLogTopics("node", "erasure", "marketplace").some,
      providers: CodexConfigs.init(nodes = 0).some,
    ):
    let
      duration = 20.periods
      expiry = 10.periods
      client = clients()[0]
      clientApi = client.client
      data = await RandomChunker.example(blocks = 8)

    let (purchaseId, requestId) = await requestStorage(
      clientApi, duration = duration, expiry = expiry, data = data.some
    )

    let storageRequestedEvent = newAsyncEvent()

    proc onStorageRequested(eventResult: ?!StorageRequested) =
      assert not eventResult.isErr
      storageRequestedEvent.fire()

    await marketplaceSubscribe(StorageRequested, onStorageRequested)
    await storageRequestedEvent.wait().wait(timeout = chronos.seconds(expiry.int64))

    let
      request = await marketplace.getRequest(requestId)
      cidFromRequest = request.content.cid
      downloaded = await clientApi.downloadBytes(cidFromRequest, local = true)

    check downloaded.isOk
    check downloaded.get.toHex == data.toHex
