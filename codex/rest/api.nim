## Logos Storage
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [], gcsafe.}

import std/sequtils
import std/mimetypes
import std/os

import pkg/questionable
import pkg/questionable/results
import pkg/chronos
import pkg/presto except toJson
import pkg/metrics except toJson
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/spr as spr

import ../logutils
import ../node
import ../blocktype
import ../conf
import ../manifest
import ../streams/asyncstreamwrapper
import ../stores
import ../utils/options

import ./coders
import ./json

logScope:
  topics = "codex restapi"

declareCounter(codex_api_uploads, "codex API uploads")
declareCounter(codex_api_downloads, "codex API downloads")

proc validate(pattern: string, value: string): int {.gcsafe, raises: [Defect].} =
  0

proc formatManifest(cid: Cid, manifest: Manifest): RestContent =
  return RestContent.init(cid, manifest)

proc formatManifestBlocks(node: CodexNodeRef): Future[JsonNode] {.async.} =
  var content: seq[RestContent]

  proc addManifest(cid: Cid, manifest: Manifest) =
    content.add(formatManifest(cid, manifest))

  await node.iterateManifests(addManifest)

  return %RestContentList.init(content)

proc isPending(resp: HttpResponseRef): bool =
  ## Checks that an HttpResponseRef object is still pending; i.e.,
  ## that no body has yet been sent. This helps us guard against calling
  ## sendBody(resp: HttpResponseRef, ...) twice, which is illegal.
  return resp.getResponseState() == HttpResponseState.Empty

proc retrieveCid(
    node: CodexNodeRef, cid: Cid, local: bool = true, resp: HttpResponseRef
): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
  ## Download a file from the node in a streaming
  ## manner
  ##

  var lpStream: LPStream

  var bytes = 0
  try:
    without stream =? (await node.retrieve(cid, local)), error:
      if error of BlockNotFoundError:
        resp.status = Http404
        await resp.sendBody(
          "The requested CID could not be retrieved (" & error.msg & ")."
        )
        return
      else:
        resp.status = Http500
        await resp.sendBody(error.msg)
        return

    lpStream = stream

    # It is ok to fetch again the manifest because it will hit the cache
    without manifest =? (await node.fetchManifest(cid)), err:
      error "Failed to fetch manifest", err = err.msg
      resp.status = Http404
      await resp.sendBody(err.msg)
      return

    if manifest.mimetype.isSome:
      resp.setHeader("Content-Type", manifest.mimetype.get())
    else:
      resp.addHeader("Content-Type", "application/octet-stream")

    if manifest.filename.isSome:
      resp.setHeader(
        "Content-Disposition",
        "attachment; filename=\"" & manifest.filename.get() & "\"",
      )
    else:
      resp.setHeader("Content-Disposition", "attachment")

    # For erasure-coded datasets, we need to return the _original_ length; i.e.,
    # the length of the non-erasure-coded dataset, as that's what we will be
    # returning to the client.
    resp.setHeader("Content-Length", $(manifest.datasetSize.int))

    await resp.prepare(HttpResponseStreamType.Plain)

    while not stream.atEof:
      var
        buff = newSeqUninitialized[byte](DefaultBlockSize.int)
        len = await stream.readOnce(addr buff[0], buff.len)

      buff.setLen(len)
      if buff.len <= 0:
        break

      bytes += buff.len

      await resp.send(addr buff[0], buff.len)
    await resp.finish()
    codex_api_downloads.inc()
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Error streaming blocks", exc = exc.msg
    resp.status = Http500
    if resp.isPending():
      await resp.sendBody(exc.msg)
  finally:
    info "Sent bytes", cid = cid, bytes
    if not lpStream.isNil:
      await lpStream.close()

proc buildCorsHeaders(
    httpMethod: string, allowedOrigin: Option[string]
): seq[(string, string)] =
  var headers: seq[(string, string)] = newSeq[(string, string)]()

  if corsOrigin =? allowedOrigin:
    headers.add(("Access-Control-Allow-Origin", corsOrigin))
    headers.add(("Access-Control-Allow-Methods", httpMethod & ", OPTIONS"))
    headers.add(("Access-Control-Max-Age", "86400"))

  return headers

proc setCorsHeaders(resp: HttpResponseRef, httpMethod: string, origin: string) =
  resp.setHeader("Access-Control-Allow-Origin", origin)
  resp.setHeader("Access-Control-Allow-Methods", httpMethod & ", OPTIONS")
  resp.setHeader("Access-Control-Max-Age", "86400")

proc getFilenameFromContentDisposition(contentDisposition: string): ?string =
  if not ("filename=" in contentDisposition):
    return string.none

  let parts = contentDisposition.split("filename=\"")

  if parts.len < 2:
    return string.none

  let filename = parts[1].strip()
  return filename[0 ..^ 2].some

proc initDataApi(node: CodexNodeRef, repoStore: RepoStore, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin # prevents capture inside of api defintion

  router.api(MethodOptions, "/api/storage/v1/data") do(
    resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("POST", corsOrigin)
      resp.setHeader(
        "Access-Control-Allow-Headers", "content-type, content-disposition"
      )

    resp.status = Http204
    await resp.sendBody("")

  router.rawApi(MethodPost, "/api/storage/v1/data") do() -> RestApiResponse:
    ## Upload a file in a streaming manner
    ##

    trace "Handling file upload"
    var bodyReader = request.getBodyReader()
    if bodyReader.isErr():
      return RestApiResponse.error(Http500, msg = bodyReader.error())

    # Attempt to handle `Expect` header
    # some clients (curl), wait 1000ms
    # before giving up
    #
    await request.handleExpect()

    var mimetype = request.headers.getString(ContentTypeHeader).some

    if mimetype.get() != "":
      let mimetypeVal = mimetype.get()
      var m = newMimetypes()
      let extension = m.getExt(mimetypeVal, "")
      if extension == "":
        return RestApiResponse.error(
          Http422, "The MIME type '" & mimetypeVal & "' is not valid."
        )
    else:
      mimetype = string.none

    const ContentDispositionHeader = "Content-Disposition"
    let contentDisposition = request.headers.getString(ContentDispositionHeader)
    let filename = getFilenameFromContentDisposition(contentDisposition)

    if filename.isSome and not isValidFilename(filename.get()):
      return RestApiResponse.error(Http422, "The filename is not valid.")

    # Here we could check if the extension matches the filename if needed

    let reader = bodyReader.get()

    try:
      without cid =? (
        await node.store(
          AsyncStreamWrapper.new(reader = AsyncStreamReader(reader)),
          filename = filename,
          mimetype = mimetype,
        )
      ), error:
        error "Error uploading file", exc = error.msg
        return RestApiResponse.error(Http500, error.msg)

      codex_api_uploads.inc()
      trace "Uploaded file", cid
      return RestApiResponse.response($cid)
    except CancelledError:
      trace "Upload cancelled error"
      return RestApiResponse.error(Http500)
    except AsyncStreamError:
      trace "Async stream error"
      return RestApiResponse.error(Http500)
    finally:
      await reader.closeWait()

  router.api(MethodGet, "/api/storage/v1/data") do() -> RestApiResponse:
    let json = await formatManifestBlocks(node)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodOptions, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET,DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodGet, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    var headers = buildCorsHeaders("GET", allowedOrigin)

    ## Download a file from the local node in a streaming
    ## manner
    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    await node.retrieveCid(cid.get(), local = true, resp = resp)

  router.api(MethodDelete, "/api/storage/v1/data/{cid}") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Deletes either a single block or an entire dataset
    ## from the local node. Does nothing and returns 204
    ## if the dataset is not locally available.
    ##
    var headers = buildCorsHeaders("DELETE", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if err =? (await node.delete(cid.get())).errorOption:
      return RestApiResponse.error(Http500, err.msg, headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("DELETE", corsOrigin)

    resp.status = Http204
    await resp.sendBody("")

  router.api(MethodPost, "/api/storage/v1/data/{cid}/network") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network to the local node
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    # Start fetching the dataset in the background
    node.fetchDatasetAsyncTask(manifest)

    let json = %formatManifest(cid.get(), manifest)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/data/{cid}/network/stream") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download a file from the network in a streaming
    ## manner
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    if corsOrigin =? allowedOrigin:
      resp.setCorsHeaders("GET", corsOrigin)
      resp.setHeader("Access-Control-Headers", "X-Requested-With")

    resp.setHeader("Access-Control-Expose-Headers", "Content-Disposition")
    await node.retrieveCid(cid.get(), local = false, resp = resp)

  router.api(MethodGet, "/api/storage/v1/data/{cid}/network/manifest") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Download only the manifest.
    ##

    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    without manifest =? (await node.fetchManifest(cid.get())), err:
      error "Failed to fetch manifest", err = err.msg
      return RestApiResponse.error(Http404, err.msg, headers = headers)

    let json = %formatManifest(cid.get(), manifest)
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/data/{cid}/exists") do(
    cid: Cid, resp: HttpResponseRef
  ) -> RestApiResponse:
    ## Only test if the give CID is available in the local store
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if cid.isErr:
      return RestApiResponse.error(Http400, $cid.error(), headers = headers)

    let cid = cid.get()
    let hasCid = await node.hasLocalBlock(cid)

    let json = %*{$cid: hasCid}
    return RestApiResponse.response($json, contentType = "application/json")

  router.api(MethodGet, "/api/storage/v1/space") do() -> RestApiResponse:
    let json =
      %RestRepoStore(
        totalBlocks: repoStore.totalBlocks,
        quotaMaxBytes: repoStore.quotaMaxBytes,
        quotaUsedBytes: repoStore.quotaUsedBytes,
        quotaReservedBytes: repoStore.quotaReservedBytes,
      )
    return RestApiResponse.response($json, contentType = "application/json")

proc initNodeApi(node: CodexNodeRef, conf: CodexConf, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  ## various node management api's
  ##
  router.api(MethodGet, "/api/storage/v1/spr") do() -> RestApiResponse:
    ## Returns node SPR in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      without spr =? node.discovery.dhtRecord:
        return RestApiResponse.response(
          "", status = Http503, contentType = "application/json", headers = headers
        )

      if $preferredContentType().get() == "text/plain":
        return RestApiResponse.response(
          spr.toURI, contentType = "text/plain", headers = headers
        )
      else:
        return RestApiResponse.response(
          $ %*{"spr": spr.toURI}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/storage/v1/peerid") do() -> RestApiResponse:
    ## Returns node's peerId in requested format, json or text.
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let id = $node.switch.peerInfo.peerId

      if $preferredContentType().get() == "text/plain":
        return
          RestApiResponse.response(id, contentType = "text/plain", headers = headers)
      else:
        return RestApiResponse.response(
          $ %*{"id": id}, contentType = "application/json", headers = headers
        )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodGet, "/api/storage/v1/connect/{peerId}") do(
    peerId: PeerId, addrs: seq[MultiAddress]
  ) -> RestApiResponse:
    ## Connect to a peer
    ##
    ## If `addrs` param is supplied, it will be used to
    ## dial the peer, otherwise the `peerId` is used
    ## to invoke peer discovery, if it succeeds
    ## the returned addresses will be used to dial
    ##
    ## `addrs` the listening addresses of the peers to dial, eg the one specified with `--listen-addrs`
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    if peerId.isErr:
      return RestApiResponse.error(Http400, $peerId.error(), headers = headers)

    let addresses =
      if addrs.isOk and addrs.get().len > 0:
        addrs.get()
      else:
        without peerRecord =? (await node.findPeer(peerId.get())):
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)
        peerRecord.addresses.mapIt(it.address)
    try:
      await node.connect(peerId.get(), addresses)
      return
        RestApiResponse.response("Successfully connected to peer", headers = headers)
    except DialFailedError:
      return RestApiResponse.error(Http400, "Unable to dial peer", headers = headers)
    except CatchableError:
      return
        RestApiResponse.error(Http500, "Unknown error dialling peer", headers = headers)

proc initDebugApi(node: CodexNodeRef, conf: CodexConf, router: var RestRouter) =
  let allowedOrigin = router.allowedOrigin

  router.api(MethodGet, "/api/storage/v1/debug/info") do() -> RestApiResponse:
    ## Print rudimentary node information
    ##
    var headers = buildCorsHeaders("GET", allowedOrigin)

    try:
      let table = RestRoutingTable.init(node.discovery.protocol.routingTable)

      let json =
        %*{
          "id": $node.switch.peerInfo.peerId,
          "addrs": node.switch.peerInfo.addrs.mapIt($it),
          "repo": $conf.dataDir,
          "spr":
            if node.discovery.dhtRecord.isSome:
              node.discovery.dhtRecord.get.toURI
            else:
              "",
          "announceAddresses": node.discovery.announceAddrs,
          "table": table,
          "storage": {"version": $codexVersion, "revision": $codexRevision},
        }

      # return pretty json for human readability
      return RestApiResponse.response(
        json.pretty(), contentType = "application/json", headers = headers
      )
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  router.api(MethodPost, "/api/storage/v1/debug/chronicles/loglevel") do(
    level: Option[string]
  ) -> RestApiResponse:
    ## Set log level at run time
    ##
    ## e.g. `chronicles/loglevel?level=DEBUG`
    ##
    ## `level` - chronicles log level
    ##
    var headers = buildCorsHeaders("POST", allowedOrigin)

    try:
      without res =? level and level =? res:
        return RestApiResponse.error(Http400, "Missing log level", headers = headers)

      try:
        {.gcsafe.}:
          updateLogLevel(level)
      except CatchableError as exc:
        return RestApiResponse.error(Http500, exc.msg, headers = headers)

      return RestApiResponse.response("")
    except CatchableError as exc:
      trace "Excepting processing request", exc = exc.msg
      return RestApiResponse.error(Http500, headers = headers)

  when storage_enable_api_debug_peers:
    router.api(MethodGet, "/api/storage/v1/debug/peer/{peerId}") do(
      peerId: PeerId
    ) -> RestApiResponse:
      var headers = buildCorsHeaders("GET", allowedOrigin)

      try:
        trace "debug/peer start"
        without peerRecord =? (await node.findPeer(peerId.get())):
          trace "debug/peer peer not found!"
          return
            RestApiResponse.error(Http400, "Unable to find Peer!", headers = headers)

        let json = %RestPeerRecord.init(peerRecord)
        trace "debug/peer returning peer record"
        return RestApiResponse.response($json, headers = headers)
      except CatchableError as exc:
        trace "Excepting processing request", exc = exc.msg
        return RestApiResponse.error(Http500, headers = headers)

proc initRestApi*(
    node: CodexNodeRef,
    conf: CodexConf,
    repoStore: RepoStore,
    corsAllowedOrigin: ?string,
): RestRouter =
  var router = RestRouter.init(validate, corsAllowedOrigin)

  initDataApi(node, repoStore, router)
  initNodeApi(node, conf, router)
  initDebugApi(node, conf, router)

  return router
