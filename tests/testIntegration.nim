import std/osproc
import std/os
import std/streams
import std/strutils
import std/httpclient
import std/json
import pkg/asynctest
import pkg/chronos

suite "Integration tests":

  let workingDir = currentSourcePath() / ".." / ".."

  var node1, node2: Process
  var client: HttpClient

  proc startNode(args: openArray[string]): Process =
    result = startProcess("build" / "dagger", workingDir, args)
    for line in result.outputStream.lines:
      if line.contains("Started dagger node"):
        break

  proc stop(node: Process) =
    node.terminate()
    discard node.waitForExit()
    node.close()

  setup:
    node1 = startNode ["--api-port=8080", "--udp-port=8090"]
    node2 = startNode ["--api-port=8081", "--udp-port=8091"]
    client = newHttpClient()

  teardown:
    client.close()
    node1.stop()
    node2.stop()

  test "nodes can print their peer information":
    let info1 = client.get("http://localhost:8080/api/dagger/v1/info").body
    let info2 = client.get("http://localhost:8081/api/dagger/v1/info").body
    check info1 != info2

  test "node handles new storage availability":
    let baseurl = "http://localhost:8080/api/dagger/v1"
    let url = baseurl & "/sales/availability"
    let json = %*{
      "size": "0x1",
      "duration": "0x2",
      "minPrice": "0x3"
    }
    let response = client.post(url, $json)
    check response.status == "200 OK"
