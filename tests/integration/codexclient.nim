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

proc requestStorage*(client: CodexClient,
                     cid: string,
                     duration: uint64,
                     reward: uint64,
                     proofProbability: uint64,
                     expiry: UInt256,
                     collateral: uint64): string =
  let url = client.baseurl & "/storage/request/" & cid
  let json = %*{
    "duration": "0x" & duration.toHex,
    "reward": "0x" & reward.toHex,
    "proofProbability": "0x" & proofProbability.toHex,
    "expiry": "0x" & expiry.toHex,
    "collateral": "0x" & collateral.toHex,
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  response.body

proc getPurchase*(client: CodexClient, purchase: string): JsonNode =
  let url = client.baseurl & "/storage/purchases/" & purchase
  let body = client.http.getContent(url)
  parseJson(body).catch |? nil

proc postAvailability*(client: CodexClient,
                       size, duration, minPrice: uint64, maxCollateral: uint64): JsonNode =
  let url = client.baseurl & "/sales/availability"
  let json = %*{
    "size": "0x" & size.toHex,
    "duration": "0x" & duration.toHex,
    "minPrice": "0x" & minPrice.toHex,
    "maxCollateral": "0x" & maxCollateral.toHex
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  parseJson(response.body)

proc getAvailabilities*(client: CodexClient): JsonNode =
  let url = client.baseurl & "/sales/availability"
  let body = client.http.getContent(url)
  parseJson(body)

proc close*(client: CodexClient) =
  client.http.close()

proc restart*(client: CodexClient) =
  client.http.close()
  client.http = newHttpClient()
