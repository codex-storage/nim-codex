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
  session: HttpSessionRef

proc new*(_: type CodexClient, baseurl: string): CodexClient =
  CodexClient(session: HttpSessionRef.new(), baseurl: baseurl)

proc close*(self: CodexClient): Future[void] {.async: (raises: []).} =
  await self.session.closeWait()

proc request(
    self: CodexClient,
    httpMethod: httputils.HttpMethod,
    url: string,
    body: openArray[char] = [],
    headers: openArray[HttpHeaderTuple] = [],
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  HttpClientRequestRef
  .new(
    self.session,
    url,
    httpMethod,
    version = HttpVersion11,
    flags = {},
    maxResponseHeadersSize = HttpMaxHeadersSize,
    headers = headers,
    body = body.toOpenArrayByte(0, len(body) - 1),
  ).get
  .send()

proc post*(
    self: CodexClient,
    url: string,
    body: string = "",
    headers: seq[HttpHeaderTuple] = @[],
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodPost, url, headers = headers, body = body)

proc get(
    self: CodexClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodGet, url, headers = headers)

proc delete(
    self: CodexClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodDelete, url, headers = headers)

proc patch*(
    self: CodexClient,
    url: string,
    body: string = "",
    headers: seq[HttpHeaderTuple] = @[],
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return self.request(MethodPatch, url, headers = headers, body = body)

proc body*(
    response: HttpClientResponseRef
): Future[string] {.async: (raises: [CancelledError, HttpError]).} =
  return bytesToString (await response.getBodyBytes())

proc getContent(
    client: CodexClient, url: string, headers: seq[HttpHeaderTuple] = @[]
): Future[string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.get(url, headers)
  return await response.body

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

proc uploadRaw*(
    client: CodexClient, contents: string, headers: seq[HttpHeaderTuple] = @[]
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.post(client.baseurl & "/data", body = contents, headers = headers)

proc upload*(
    client: CodexClient, contents: string
): Future[?!Cid] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.uploadRaw(contents)
  assert response.status == 200
  Cid.init(await response.body).mapFailure

proc upload*(
    client: CodexClient, bytes: seq[byte]
): Future[?!Cid] {.async: (raw: true).} =
  return client.upload(string.fromBytes(bytes))

proc downloadRaw*(
    client: CodexClient, cid: string, local = false
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return
    client.get(client.baseurl & "/data/" & cid & (if local: "" else: "/network/stream"))

proc downloadBytes*(
    client: CodexClient, cid: Cid, local = false
): Future[?!seq[byte]] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.downloadRaw($cid, local = local)

  if response.status != 200:
    return failure($response.status)

  success await response.getBodyBytes()

proc download*(
    client: CodexClient, cid: Cid, local = false
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  without response =? await client.downloadBytes(cid, local = local), err:
    return failure(err)
  return success bytesToString(response)

proc downloadNoStream*(
    client: CodexClient, cid: Cid
): Future[?!string] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.post(client.baseurl & "/data/" & $cid & "/network")

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

proc deleteRaw*(
    client: CodexClient, cid: string
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.delete(client.baseurl & "/data/" & cid)

proc delete*(
    client: CodexClient, cid: Cid
): Future[?!void] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.deleteRaw($cid)

  if response.status != 204:
    return failure($response.status)

  success()

proc listRaw*(
    client: CodexClient
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  return client.get(client.baseurl & "/data")

proc list*(
    client: CodexClient
): Future[?!RestContentList] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.listRaw()

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
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
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

proc requestStorage*(
    client: CodexClient,
    cid: Cid,
    duration: uint64,
    pricePerBytePerSecond: UInt256,
    proofProbability: UInt256,
    expiry: uint64,
    collateralPerByte: UInt256,
    nodes: uint = 3,
    tolerance: uint = 1,
): Future[?!PurchaseId] {.async: (raises: [CancelledError, HttpError]).} =
  ## Call request storage REST endpoint
  ##
  let
    response = await client.requestStorageRaw(
      cid, duration, pricePerBytePerSecond, proofProbability, collateralPerByte, expiry,
      nodes, tolerance,
    )
    body = await response.body

  if response.status != 200:
    doAssert(false, body)
  PurchaseId.fromHex(body).catch

proc getPurchase*(
    client: CodexClient, purchaseId: PurchaseId
): Future[?!RestPurchase] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/storage/purchases/" & purchaseId.toHex
  try:
    let body = await client.getContent(url)
    return RestPurchase.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc getSalesAgent*(
    client: CodexClient, slotId: SlotId
): Future[?!RestSalesAgent] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/sales/slots/" & slotId.toHex
  try:
    let body = await client.getContent(url)
    return RestSalesAgent.fromJson(body)
  except CatchableError as e:
    return failure e.msg

proc postAvailabilityRaw*(
    client: CodexClient,
    totalSize, duration: uint64,
    minPricePerBytePerSecond, totalCollateral: UInt256,
    enabled: ?bool = bool.none,
    until: ?SecondsSince1970 = SecondsSince1970.none,
): Future[HttpClientResponseRef] {.async: (raises: [CancelledError, HttpError]).} =
  ## Post sales availability endpoint
  ##
  let url = client.baseurl & "/sales/availability"
  let json =
    %*{
      "totalSize": totalSize,
      "duration": duration,
      "minPricePerBytePerSecond": minPricePerBytePerSecond,
      "totalCollateral": totalCollateral,
      "enabled": enabled,
      "until": until,
    }
  return await client.post(url, $json)

proc postAvailability*(
    client: CodexClient,
    totalSize, duration: uint64,
    minPricePerBytePerSecond, totalCollateral: UInt256,
    enabled: ?bool = bool.none,
    until: ?SecondsSince1970 = SecondsSince1970.none,
): Future[?!Availability] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.postAvailabilityRaw(
    totalSize = totalSize,
    duration = duration,
    minPricePerBytePerSecond = minPricePerBytePerSecond,
    totalCollateral = totalCollateral,
    enabled = enabled,
    until = until,
  )

  let body = await response.body

  doAssert response.status == 201,
    "expected 201 Created, got " & $response.status & ", body: " & body
  Availability.fromJson(body)

proc patchAvailabilityRaw*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, freeSize, duration: ?uint64 = uint64.none,
    minPricePerBytePerSecond, totalCollateral: ?UInt256 = UInt256.none,
    enabled: ?bool = bool.none,
    until: ?SecondsSince1970 = SecondsSince1970.none,
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
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

  if enabled =? enabled:
    json["enabled"] = %enabled

  if until =? until:
    json["until"] = %until

  client.patch(url, $json)

proc patchAvailability*(
    client: CodexClient,
    availabilityId: AvailabilityId,
    totalSize, duration: ?uint64 = uint64.none,
    minPricePerBytePerSecond, totalCollateral: ?UInt256 = UInt256.none,
    enabled: ?bool = bool.none,
    until: ?SecondsSince1970 = SecondsSince1970.none,
): Future[void] {.async: (raises: [CancelledError, HttpError]).} =
  let response = await client.patchAvailabilityRaw(
    availabilityId,
    totalSize = totalSize,
    duration = duration,
    minPricePerBytePerSecond = minPricePerBytePerSecond,
    totalCollateral = totalCollateral,
    enabled = enabled,
    until = until,
  )
  doAssert response.status == 204, "expected No Content, got " & $response.status

proc getAvailabilities*(
    client: CodexClient
): Future[?!seq[Availability]] {.async: (raises: [CancelledError, HttpError]).} =
  ## Call sales availability REST endpoint
  let url = client.baseurl & "/sales/availability"
  let body = await client.getContent(url)
  seq[Availability].fromJson(body)

proc getAvailabilityReservations*(
    client: CodexClient, availabilityId: AvailabilityId
): Future[?!seq[Reservation]] {.async: (raises: [CancelledError, HttpError]).} =
  ## Retrieves Availability's Reservations
  let url = client.baseurl & "/sales/availability/" & $availabilityId & "/reservations"
  let body = await client.getContent(url)
  seq[Reservation].fromJson(body)

proc purchaseStateIs*(
    client: CodexClient, id: PurchaseId, state: string
): Future[bool] {.async: (raises: [CancelledError, HttpError]).} =
  (await client.getPurchase(id)).option .? state == some state

proc saleStateIs*(
    client: CodexClient, id: SlotId, state: string
): Future[bool] {.async: (raises: [CancelledError, HttpError]).} =
  (await client.getSalesAgent(id)).option .? state == some state

proc requestId*(
    client: CodexClient, id: PurchaseId
): Future[?RequestId] {.async: (raises: [CancelledError, HttpError]).} =
  return (await client.getPurchase(id)).option .? requestId

proc buildUrl*(client: CodexClient, path: string): string =
  return client.baseurl & path
