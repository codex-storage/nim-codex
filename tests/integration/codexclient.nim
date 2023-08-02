import std/httpclient
import std/json
import std/strutils
import pkg/stint
import pkg/questionable/results

type CodexClient* = ref object
  http: HttpClient
  baseurl: string

proc new*(_: type CodexClient, baseurl: string): CodexClient =
  CodexClient(http: newHttpClient(), baseurl: baseurl)

proc info*(client: CodexClient): JsonNode =
  let url = client.baseurl & "/debug/info"
  client.http.getContent(url).parseJson()

proc setLogLevel*(client: CodexClient, level: string) =
  let url = client.baseurl & "/debug/chronicles/loglevel?level=" & level
  let headers = newHttpHeaders({"Content-Type": "text/plain"})
  let response = client.http.request(url, httpMethod=HttpPost, headers=headers)
  assert response.status == "200 OK"

proc upload*(client: CodexClient, contents: string): string =
  let response = client.http.post(client.baseurl & "/upload", contents)
  assert response.status == "200 OK"
  response.body

proc requestStorage*(
    client: CodexClient,
    cid: string,
    duration: uint64,
    reward: uint64,
    proofProbability: uint64,
    expiry: UInt256,
    collateral: uint64,
    nodes: uint = 1,
    tolerance: uint = 0
): string =
  ## Call request storage REST endpoint
  ## 
  let url = client.baseurl & "/storage/request/" & cid
  let json = %*{
    "duration": $duration,
    "reward": $reward,
    "proofProbability": $proofProbability,
    "expiry": $expiry,
    "collateral": $collateral,
    "nodes": nodes,
    "tolerance": $tolerance
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  response.body

proc getPurchase*(client: CodexClient, purchase: string): JsonNode =
  let url = client.baseurl & "/storage/purchases/" & purchase
  let body = client.http.getContent(url)
  parseJson(body).catch |? nil

proc getSlots*(client: CodexClient): JsonNode =
  let url = client.baseurl & "/sales/slots"
  let body = client.http.getContent(url)
  parseJson(body).catch |? nil

proc postAvailability*(
    client: CodexClient,
    size, duration, minPrice: uint64,
    maxCollateral: uint64
): JsonNode =
  ## Post sales availability endpoint
  ## 
  let url = client.baseurl & "/sales/availability"
  let json = %*{
    "size": $size,
    "duration": $duration,
    "minPrice": $minPrice,
    "maxCollateral": $maxCollateral,
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  parseJson(response.body)

proc getAvailabilities*(client: CodexClient): JsonNode =
  ## Call sales availability REST endpoint
  let url = client.baseurl & "/sales/availability"
  let body = client.http.getContent(url)
  parseJson(body)

proc close*(client: CodexClient) =
  client.http.close()

proc restart*(client: CodexClient) =
  client.http.close()
  client.http = newHttpClient()
