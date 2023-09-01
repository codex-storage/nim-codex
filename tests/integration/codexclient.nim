import std/httpclient
import std/strutils
from pkg/libp2p import Cid, `$`, init
import pkg/chronicles
import pkg/stint
import pkg/questionable/results
import pkg/codex/rest/json
import pkg/codex/purchasing
import pkg/codex/errors
import pkg/codex/sales/reservations

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

proc upload*(client: CodexClient, contents: string): ?!Cid =
  let response = client.http.post(client.baseurl & "/upload", contents)
  assert response.status == "200 OK"
  Cid.init(response.body).mapFailure

proc requestStorage*(
    client: CodexClient,
    cid: Cid,
    duration: UInt256,
    reward: UInt256,
    proofProbability: UInt256,
    expiry: UInt256,
    collateral: UInt256,
    nodes: uint = 1,
    tolerance: uint = 0
): ?!PurchaseId =
  ## Call request storage REST endpoint
  ##
  let url = client.baseurl & "/storage/request/" & $cid
  let json = %*{
    "duration": duration,
    "reward": reward,
    "proofProbability": proofProbability,
    "expiry": expiry,
    "collateral": collateral,
    "nodes": nodes,
    "tolerance": tolerance
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  PurchaseId.fromHex(response.body).catch

proc getPurchase*(client: CodexClient, purchaseId: PurchaseId): ?!RestPurchase =
  let url = client.baseurl & "/storage/purchases/" & purchaseId.toHex
  let body = client.http.getContent(url)
  let json = ? parseJson(body).catch
  RestPurchase.fromJson(json)

proc getSlots*(client: CodexClient): JsonNode =
  let url = client.baseurl & "/sales/slots"
  let body = client.http.getContent(url)
  parseJson(body).catch |? nil

proc postAvailability*(
    client: CodexClient,
    size, duration, minPrice, maxCollateral: UInt256
): ?!Availability =
  ## Post sales availability endpoint
  ##
  let url = client.baseurl & "/sales/availability"
  let json = %*{
    "size": size,
    "duration": duration,
    "minPrice": minPrice,
    "maxCollateral": maxCollateral,
  }
  let response = client.http.post(url, $json)
  assert response.status == "200 OK"
  Availability.fromJson(response.body.parseJson)

proc getAvailabilities*(client: CodexClient): ?!seq[Availability] =
  ## Call sales availability REST endpoint
  let url = client.baseurl & "/sales/availability"
  let body = client.http.getContent(url)
  seq[Availability].fromJson(parseJson(body))

proc close*(client: CodexClient) =
  client.http.close()

proc restart*(client: CodexClient) =
  client.http.close()
  client.http = newHttpClient()
