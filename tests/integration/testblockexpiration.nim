import ../examples
import ./multinodes

multinodesuite "Node block expiration tests":
  var content: seq[byte]

  setup:
    content = await RandomChunker.example(blocks = 8)

  test "node retains not-expired file",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        .withBlockTtl(0, 10)
        .withBlockMaintenanceInterval(0, 1).some,
      providers: CodexConfigs.none,
    ):
    let client = clients()[0]
    let clientApi = client.client

    let contentId = (await clientApi.upload(content)).get

    await sleepAsync(2.seconds)

    let download = await clientApi.download(contentId, local = true)

    check:
      download.isOk
      download.get == string.fromBytes(content)

  test "node deletes expired file",
    NodeConfigs(
      clients: CodexConfigs
        .init(nodes = 1)
        .withBlockTtl(0, 1)
        .withBlockMaintenanceInterval(0, 1).some,
      providers: CodexConfigs.none,
    ):
    let client = clients()[0]
    let clientApi = client.client

    let contentId = (await clientApi.upload(content)).get

    await sleepAsync(3.seconds)

    let download = await clientApi.download(contentId, local = true)

    check:
      download.isFailure
      download.error.msg == "404"
