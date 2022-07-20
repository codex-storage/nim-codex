import std/osproc
import std/httpclient
import std/json
import pkg/chronos
import ./ethertest
import ./contracts/time
import ./integration/nodes
import ./integration/tokens

ethersuite "Integration tests":

  var node1, node2: Process
  var baseurl1, baseurl2: string
  var client: HttpClient

  setup:
    await provider.getSigner(accounts[0]).mint()
    await provider.getSigner(accounts[1]).mint()
    await provider.getSigner(accounts[1]).deposit()
    node1 = startNode [
      "--api-port=8080",
      "--udp-port=8090",
      "--eth-account=" & $accounts[0]
    ]
    node2 = startNode [
      "--api-port=8081",
      "--udp-port=8091",
      "--eth-account=" & $accounts[1]
    ]
    baseurl1 = "http://localhost:8080/api/codex/v1"
    baseurl2 = "http://localhost:8081/api/codex/v1"
    client = newHttpClient()

  teardown:
    client.close()
    node1.stop()
    node2.stop()

  test "nodes can print their peer information":
    let info1 = client.get(baseurl1 & "/info").body
    let info2 = client.get(baseurl2 & "/info").body
    check info1 != info2

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
    let json = %*{"duration": "0x1", "reward": "0x2"}
    let response = client.post(url, $json)
    check response.status == "200 OK"

  test "node retrieves purchase status":
    let cid = client.post(baseurl1 & "/upload", "some file contents").body
    let request = %*{"duration": "0x1", "reward": "0x2"}
    let id = client.post(baseurl1 & "/storage/request/" & cid, $request).body
    let response = client.get(baseurl1 & "/storage/purchases/" & id)
    check response.status == "200 OK"
    let json = parseJson(response.body)
    check json["request"]["ask"]["duration"].getStr == "0x1"
    check json["request"]["ask"]["reward"].getStr == "0x2"

  test "nodes negotiate contracts on the marketplace":
    proc sell =
      let json = %*{"size": "0x1F00", "duration": "0x200", "minPrice": "0x300"}
      discard client.post(baseurl2 & "/sales/availability", $json)

    proc available: JsonNode =
      client.get(baseurl2 & "/sales/availability").body.parseJson

    proc upload: string =
      client.post(baseurl1 & "/upload", "some file contents").body

    proc buy(cid: string): string =
      let expiry = ((waitFor provider.currentTime()) + 30).toHex
      let json = %*{"duration": "0x100", "reward": "0x400", "expiry": expiry}
      client.post(baseurl1 & "/storage/request/" & cid, $json).body

    proc finish(purchase: string): Future[JsonNode] {.async.} =
      while true:
        let response = client.get(baseurl1 & "/storage/purchases/" & purchase)
        let json = parseJson(response.body)
        if json["finished"].getBool: return json
        await sleepAsync(1.seconds)

    sell()
    let purchase = waitFor upload().buy().finish()

    check purchase["error"].getStr == ""
    check purchase["selected"].getStr == $accounts[1]
    check available().len == 0
