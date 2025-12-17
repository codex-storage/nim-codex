import std/strutils

from pkg/libp2p import Cid, `$`, init
import pkg/stint
import pkg/questionable/results
import pkg/chronos/apps/http/[httpserver, shttpserver, httpclient, httptable]
import pkg/codex/logutils
import pkg/codex/rest/json
import pkg/codex/errors

export httptable, httpclient

type CodexClient* = ref object
  baseurl: string
  session: HttpSessionRef

type HasBlockResponse = object
  has: bool

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

proc buildUrl*(client: CodexClient, path: string): string =
  return client.baseurl & path

proc hasBlock*(
    client: CodexClient, cid: Cid
): Future[?!bool] {.async: (raises: [CancelledError, HttpError]).} =
  let url = client.baseurl & "/data/" & $cid & "/exists"
  let body = await client.getContent(url)
  let response = HasBlockResponse.fromJson(body)
  if response.isErr:
    return failure "Failed to parse has block response"
  return response.get.has.success

proc hasBlockRaw*(
    client: CodexClient, cid: string
): Future[HttpClientResponseRef] {.
    async: (raw: true, raises: [CancelledError, HttpError])
.} =
  let url = client.baseurl & "/data/" & cid & "/exists"
  return client.get(url)
