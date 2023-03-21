import std/os
import std/httpclient
import std/json
import std/strutils
import pkg/chronos
import ../ethertest
import ../contracts/time
import ../codex/helpers/eventually
import ./nodes
import ./tokens

ethersuite "Integration tests":

  var node1, node2: NodeProcess
  var baseurl1, baseurl2: string
  var client: HttpClient

  let dataDir1 = getTempDir() / "Codex1"
  let dataDir2 = getTempDir() / "Codex2"

  setup:
    await provider.getSigner(accounts[0]).mint()
    await provider.getSigner(accounts[1]).mint()
    await provider.getSigner(accounts[1]).deposit()

    baseurl1 = "http://localhost:8080/api/codex/v1"
    baseurl2 = "http://localhost:8081/api/codex/v1"
    client = newHttpClient()

    node1 = startNode([
      "--api-port=8080",
      "--data-dir=" & dataDir1,
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8090",
      "--persistence",
      "--eth-account=" & $accounts[0]
    ], debug = false)

    let
      bootstrap = strip(
        $(parseJson(client.get(baseurl1 & "/debug/info").body)["spr"]),
        chars = {'"'})

    node2 = startNode([
      "--api-port=8081",
      "--data-dir=" & dataDir2,
      "--nat=127.0.0.1",
      "--disc-ip=127.0.0.1",
      "--disc-port=8091",
      "--bootstrap-node=" & bootstrap,
      "--persistence",
      "--eth-account=" & $accounts[1]
    ], debug = false)

  teardown:
    client.close()
    node1.stop()
    node2.stop()

    dataDir1.removeDir()
    dataDir2.removeDir()

  test "nodes can print their peer information":
    let info1 = client.get(baseurl1 & "/debug/info").body
    let info2 = client.get(baseurl2 & "/debug/info").body
    check info1 != info2

  test "nodes should set chronicles log level":
    client.headers = newHttpHeaders({ "Content-Type": "text/plain" })
    let filter = "/debug/chronicles/loglevel?level=DEBUG;TRACE:codex"
    check client.request(baseurl1 & filter, httpMethod = HttpPost, body = "").status == "200 OK"

  test "node accepts file uploads":
    let url = baseurl1 & "/upload"
    let response = client.post(url, "some file contents")
    check response.status == "200 OK"

  test "node handles new storage availability":
    let url = baseurl1 & "/sales/availability"
    let json = %*{"size": "0x1", "duration": "0x2", "minPrice": "0x3"}
    check client.post(url, $json).status == "200 OK"

  test "node lists storage that is for sale":
    let url = baseurl1 & "/sales/availability"
    let json = %*{"size": "0x1", "duration": "0x2", "minPrice": "0x3"}
    let availability = parseJson(client.post(url, $json).body)
    let response = client.get(url)
    check response.status == "200 OK"
    check %*availability in parseJson(response.body)

  test "node handles storage request":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let url = baseurl1 & "/storage/request/" & cid
    let json = %*{"duration": "0x1", "reward": "0x2", "proofProbability": "0x3"}
    let response = client.post(url, $json)
    check response.status == "200 OK"

  test "node retrieves purchase status":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let request = %*{"duration": "0x1", "reward": "0x2", "proofProbability": "0x3"}
    let id = client.post(baseurl1 & "/storage/request/" & cid, $request).body
    let response = client.get(baseurl1 & "/storage/purchases/" & id)
    check response.status == "200 OK"
    let json = parseJson(response.body)
    check json["request"]["ask"]["duration"].getStr == "0x1"
    check json["request"]["ask"]["reward"].getStr == "0x2"
    check json["request"]["ask"]["proofProbability"].getStr == "0x3"

  test "node remembers purchase status after restart":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let request = %*{"duration": "0x1", "reward": "0x2", "proofProbability": "0x3"}
    let id = client.post(baseurl1 & "/storage/request/" & cid, $request).body

    proc getPurchase(id: string): JsonNode =
      let response = client.get(baseurl1 & "/storage/purchases/" & id)
      return parseJson(response.body).catch |? nil

    check eventually getPurchase(id){"state"}.getStr == "submitted"

    node1.restart()

    client.close()
    client = newHttpClient()

    check eventually (not isNil getPurchase(id){"request"}{"ask"})
    check getPurchase(id){"request"}{"ask"}{"duration"}.getStr == "0x1"
    check getPurchase(id){"request"}{"ask"}{"reward"}.getStr == "0x2"

  test "nodes negotiate contracts on the marketplace":
    proc sell =
      let json = %*{"size": "0xFFFFF", "duration": "0x200", "minPrice": "0x300"}
      discard client.post(baseurl2 & "/sales/availability", $json)

    proc available: JsonNode =
      client.get(baseurl2 & "/sales/availability").body.parseJson

    proc upload: string =
      client.post(baseurl1 & "/upload", "some file contents").body

    proc buy(cid: string): string =
      let expiry = ((waitFor provider.currentTime()) + 30).toHex
      let json = %*{"duration": "0x100", "reward": "0x400", "proofProbability": "0x3", "expiry": expiry}
      client.post(baseurl1 & "/storage/request/" & cid, $json).body

    proc waitForStart(purchase: string): Future[JsonNode] {.async.} =
      while true:
        let response = client.get(baseurl1 & "/storage/purchases/" & purchase)
        let json = parseJson(response.body)
        if json["state"].getStr == "started": return json
        await sleepAsync(1.seconds)

    sell()
    let purchase = await upload().buy().waitForStart()

    check purchase["error"].getStr == ""
    check available().len == 0
