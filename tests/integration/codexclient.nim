import std/httpclient
import std/strutils

from pkg/libp2p import Cid, `$`, init
import pkg/stint
import pkg/questionable/results
import pkg/chronos/apps/http/[httpserver, shttpserver, httpclient, httptable]
import pkg/codex/logutils
import pkg/codex/rest/json
import pkg/codex/purchasing
import pkg/codex/errors
import pkg/codex/sales/reservations

export purchasing, httptable, httpclient

type CodexClient* = ref object
  baseurl: string
  http: HttpClient

type CodexClientError* = object of CatchableError

const HttpClientTimeoutMs = 60 * 1000

proc new*(_: type CodexClient, baseurl: string): CodexClient =
  CodexClient(http: newHttpClient(timeout = HttpClientTimeoutMs), baseurl: baseurl)

proc get(
    client: CodexClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.async: (raises: [CancelledError, HttpError]).} =
  var request =
    HttpClientRequestRef.get(HttpSessionRef.new(), url, headers = headers).get

  return await request.send()

proc post(
    client: CodexClient, url: string, body: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.async: (raises: [CancelledError, HttpError]).} =
  let request = HttpClientRequestRef.post(
    HttpSessionRef.new(), url, headers = headers, body = body
  ).get

  return await request.send()

proc delete(
    t: typedesc[HttpClientRequestRef],
    session: HttpSessionRef,
    url: string,
    version: httputils.HttpVersion = HttpVersion11,
    flags: set[HttpClientRequestFlag] = {},
    maxResponseHeadersSize: int = HttpMaxHeadersSize,
    headers: openArray[HttpHeaderTuple] = [],
    body: openArray[byte] = [],
): HttpResult[HttpClientRequestRef] =
  HttpClientRequestRef.new(
    session, url, MethodDelete, version, flags, maxResponseHeadersSize, headers, body
  )

proc delete(
    client: CodexClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.async: (raises: [CancelledError, HttpError]).} =
  let request =
    HttpClientRequestRef.delete(HttpSessionRef.new(), url, headers = headers).get

  return await request.send()

proc body*(
    response: HttpClientResponseRef
): Future[string] {.async: (raises: [CancelledError, HttpError]).} =
  return bytesToString (await response.getBodyBytes())

proc info*(
    client: CodexClient
): Future[?!JsonNode] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(client.baseurl & "/debug/info")
  return JsonNode.parse(await response.body)

proc setLogLevel*(
    client: CodexClient, level: string
): Future[void] {.async: (raises: [CancelledError, HttpError]).} =
  let
    url = client.baseurl & "/debug/chronicles/loglevel?level=" & level
    headers = @[("Content-Type", "text/plain")]
    response = await client.post(url, headers = headers, body = "")
  assert response.status == 200

proc upload*(
    client: CodexClient, contents: string
): Future[?!Cid] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.post(client.baseurl & "/data", contents)
  assert response.status == 200
  Cid.init(await response.body).mapFailure

proc upload*(
    client: CodexClient, bytes: seq[byte]
): Future[?!Cid] {.async: (raw: true).} =
  return client.upload(string.fromBytes(bytes))

proc download*(
    client: CodexClient, cid: Cid, local = false
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(
    client.baseurl & "/data/" & $cid & (if local: "" else: "/network/stream")
  )

  if response.status != 200:
    return failure($response.status)

  success await response.body

proc downloadManifestOnly*(
    client: CodexClient, cid: Cid
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response =
    await client.get(client.baseurl & "/data/" & $cid & "/network/manifest")

  if response.status != 200:
    return failure($response.status)

  success await response.body

proc downloadNoStream*(
    client: CodexClient, cid: Cid
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(client.baseurl & "/data/" & $cid & "/network")

  if response.status != 200:
    return failure($response.status)

  success await response.body

# proc downloadBytes*(
#     client: CodexClient, cid: Cid, local = false
# ): Future[?!seq[byte]] {.async.} =
#   let uri = client.baseurl & "/data/" & $cid & (if local: "" else: "/network/stream")

#   let response = client.http.get(uri)

#   if response.status != "200 OK":
#     return failure("fetch failed with status " & $response.status)

#   success response.body.toBytes

proc delete*(
    client: CodexClient, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError, HttpError]).} =
  let
    url = client.baseurl & "/data/" & $cid
    response = await client.delete(url)

  if response.status != 204:
    return failure($response.status)

  success()

proc list*(
    client: CodexClient
): Future[?!RestContentList] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/data"
  let response = await client.get(url)

  if response.status != 200:
    return failure($response.status)

  RestContentList.fromJson(await response.body)

proc space*(
    client: CodexClient
): Future[?!RestRepoStore] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/space"
  let response = await client.get(url)

  if response.status != 200:
    return failure($response.status)

  RestRepoStore.fromJson(await response.body)

proc requestStorageRaw*(
    client: CodexClient,
    cid: Cid,
    duration: uint64,
    pricePerBytePerSecond: UInt256,
    proofProbability: UInt256,
    collateralPerByte: UInt256,
    expiry: uint64 = 0,
    nodes: uint = 3,
    tolerance: uint = 1,
): Future[HttpClientResponseRef] {.async: (raw: true).} =
  ## Call request storage REST endpoint
  ##
  let url = client.baseurl & "/storage/request/" & $cid
  let json =
    %*{
      "duration": duration,
      "pricePerBytePerSecond": pricePerBytePerSecond,
      "proofProbability": proofProbability,
      "collateralPerByte": collateralPerByte,
      "nodes": nodes,
      "tolerance": tolerance,
    }

  if expiry != 0:
    json["expiry"] = %($expiry)

  return client.post(url, $json)

# proc requestStorage*(
#     client: CodexClient,
#     cid: Cid,
#     duration: uint64,
#     pricePerBytePerSecond: UInt256,
#     proofProbability: UInt256,
#     expiry: uint64,
#     collateralPerByte: UInt256,
#     nodes: uint = 3,
#     tolerance: uint = 1,
# ): ?!PurchaseId =
#   ## Call request storage REST endpoint
#   ##
#   let response = client.requestStorageRaw(
#     cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
#     nodes, tolerance,
#   )
#   if response.status != "200 OK":
#     doAssert(false, response.body)
#   PurchaseId.fromHex(response.body).catch

proc getPurchase*(client: CodexClient, purchaseId: PurchaseId): ?!RestPurchase =
  let url = client.baseurl & "/storage/purchases/" & purchaseId.toHex
  try:
    let body = client.http.getContent(url)
    return RestPurchase.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc getSalesAgent*(client: CodexClient, slotId: SlotId): ?!RestSalesAgent =
  let url = client.baseurl & "/sales/slots/" & slotId.toHex
  try:
    let body = client.http.getContent(url)
    return RestSalesAgent.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc getSlots*(client: CodexClient): ?!seq[Slot] =
  let url = client.baseurl & "/sales/slots"
  let body = client.http.getContent(url)
  seq[Slot].fromJson(body)

proc postAvailability*(
    client: CodexClient,
    totalSize, duration: uint64,
    minPricePerBytePerSecond, totalCollateral: UInt256,
): Future[?!Availability] {.async: (raises: [CancelledError, HttpError]).} =
  ## Post sales availability endpoint
  ##
  let url = client.baseurl & "/sales/availability"
  let json =
    %*{
      "totalSize": totalSize,
      "duration": duration,
      "minPricePerBytePerSecond": minPricePerBytePerSecond,
      "totalCollateral": totalCollateral,
    }
  let response = await client.post(url, $json)
  let body = await response.body

  doAssert response.status == 201,
    "expected 201 Created, got " & $response.status & ", body: " & body
  Availability.fromJson(body)

proc patchAvailabilityRaw*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, freeSize, duration: ?uint64 = uint64.none,
    minPricePerBytePerSecond, totalCollateral: ?UInt256 = UInt256.none,
): Response =
  ## Updates availability
  ##
  let url = client.baseurl & "/sales/availability/" & $availabilityId

  # TODO: Optionalize macro does not keep `serialize` pragmas so we can't use `Optionalize(RestAvailability)` here.
  var json = %*{}

  if totalSize =? totalSize:
    json["totalSize"] = %totalSize

  if freeSize =? freeSize:
    json["freeSize"] = %freeSize

  if duration =? duration:
    json["duration"] = %duration

  if minPricePerBytePerSecond =? minPricePerBytePerSecond:
    json["minPricePerBytePerSecond"] = %minPricePerBytePerSecond

  if totalCollateral =? totalCollateral:
    json["totalCollateral"] = %totalCollateral

  client.http.patch(url, $json)

proc patchAvailability*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, duration: ?uint64 = uint64.none,
    minPricePerBytePerSecond, totalCollateral: ?UInt256 = UInt256.none,
): void =
  let response = client.patchAvailabilityRaw(
    availabilityId,
    totalSize = totalSize,
    duration = duration,
    minPricePerBytePerSecond = minPricePerBytePerSecond,
    totalCollateral = totalCollateral,
  )
  doAssert response.status == "200 OK", "expected 200 OK, got " & response.status

proc getAvailabilities*(client: CodexClient): ?!seq[Availability] =
  ## Call sales availability REST endpoint
  let url = client.baseurl & "/sales/availability"
  let body = client.http.getContent(url)
  seq[Availability].fromJson(body)

proc getAvailabilityReservations*(
    client: CodexClient, availabilityId: AvailabilityId
): ?!seq[Reservation] =
  ## Retrieves Availability's Reservations
  let url = client.baseurl & "/sales/availability/" & $availabilityId & "/reservations"
  let body = client.http.getContent(url)
  seq[Reservation].fromJson(body)

proc purchaseStateIs*(client: CodexClient, id: PurchaseId, state: string): bool =
  client.getPurchase(id).option .? state == some state

proc saleStateIs*(client: CodexClient, id: SlotId, state: string): bool =
  client.getSalesAgent(id).option .? state == some state

proc requestId*(client: CodexClient, id: PurchaseId): ?RequestId =
  return client.getPurchase(id).option .? requestId

proc uploadRaw*(
    client: CodexClient, contents: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.async: (raw: true).} =
  return client.post(client.baseurl & "/data", body = contents, headers = headers)

proc listRaw*(
    client: CodexClient
): Future[HttpClientResponseRef] {.async: (raw: true).} =
  return client.get(client.baseurl & "/data")

proc downloadRaw*(
    client: CodexClient, cid: string, local = false
): Future[HttpClientResponseRef] {.async: (raw: true).} =
  return
    client.get(client.baseurl & "/data/" & cid & (if local: "" else: "/network/stream"))

proc deleteRaw*(
    client: CodexClient, cid: string
): Future[HttpClientResponseRef] {.async: (raw: true).} =
  return client.delete(client.baseurl & "/data/" & cid)
