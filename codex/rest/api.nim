## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises

push: {.upraises: [].}


import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/metrics
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils

import pkg/libp2p
import pkg/libp2p/routing_record
import pkg/codexdht/discv5/spr as spr

import ../node
import ../blocktype
import ../conf
import ../contracts except `%*`, `%` # imported from contracts/marketplace (exporting ethers)
import ../streams

import ./coders
import ./json

logScope:
  topics = "codex restapi"

declareCounter(codex_api_uploads, "codex API uploads")
declareCounter(codex_api_downloads, "codex API downloads")

proc validate(
  pattern: string,
  value: string): int
  {.gcsafe, raises: [Defect].} =
  0

proc formatManifestBlocks(node: CodexNodeRef): Future[JsonNode] {.async.} =
  var content: seq[RestContent] = @[]

  proc formatManifest(cid: Cid, manifest: Manifest) =
    let restContent = RestContent.init(cid, manifest)
    content.add(restContent)

  await node.iterateManifests(formatManifest)
  return %content

proc initContentApi(node: CodexNodeRef, router: var RestRouter) =
  router.rawApi(
    MethodPost,
    "/api/codex/v1/content") do (
    ) -> RestApiResponse:
      ## Upload a file in a streaming manner
      ##

      trace "Handling file upload"
      var bodyReader = request.getBodyReader()
      if bodyReader.isErr():
        return RestApiResponse.error(Http500)

      # Attempt to handle `Expect` header
      # some clients (curl), wait 1000ms
      # before giving up
      #
      await request.handleExpect()

      let
        reader = bodyReader.get()

      try:
        without cid =? (
          await node.store(AsyncStreamWrapper.new(reader = AsyncStreamReader(reader)))), error:
          trace "Error uploading file", exc = error.msg
          return RestApiResponse.error(Http500, error.msg)

        codex_api_uploads.inc()
        trace_a"U_dloaded file", cid
        return RestApiResponse.response($cid)
      except CancelledError:
        trace "Upload cancelled error"
        return RestApiResponse.error(Http500)
      except AsyncStreamError:
        trace "Async stream error"
        return RestApiResponse.error(Http500)
      finally:
        await reader.closeWait()

      trace "Something went wrong error"
      return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/content/local") do () -> RestApiResponse:
      let json = await formatManifestBlocks(node)
      return RestApiResponse.response($json, contentType="application/json")

  router.api(
    MethodGet,
    "/api/codex/v1/content/cid/{cid}") do (
      cid: Cid, resp: HttpResponseRef) -> RestApiResponse:
      ## Download a file from the node in a streaming
      ## manner
      ##

      if cid.isErr:
        return RestApiResponse.error(
          Http400,
          $cid.error())

      var
        stream: LPStream

      var bytes = 0
      try:
        without stream =? (await node.retrieve(cid.get())), error:
          return RestApiResponse.error(Http404, error.msg)

        resp.addHeader("Content-Type", "application/octet-stream")
        await resp.prepareChunked()

        while not stream.atEof:
          var
            buff = newSeqUninitialized[byte](DefaultBlockSize.int)
            len = await stream.readOnce(addr buff[0], buff.len)

          buff.setLen(len)
          if buff.len <= 0:
            break

          bytes += buff.len
          trace "Sending chunk", size = buff.len
          await resp.sendChunk(addr buff[0], buff.len)
        await resp.finish()
        codex_api_downloads.inc()
      except CatchableError as exc:
        trace "Excepting streaming blocks", exc = exc.msg
        return RestApiResponse.error(Http500)
      finally:
        trace "Sent bytes", cid = cid.get(), bytes
        if not stream.isNil:
          await stream.close()

proc initSalesApi(node: CodexNodeRef, router: var RestRouter) =
  router.api(
    MethodGet,
    "/api/codex/v1/sales/slots") do () -> RestApiResponse:
      ## Returns active slots for the host

      without contracts =? node.contracts.host:
        return RestApiResponse.error(Http503, "Sales unavailable")

      let json = %(await contracts.sales.mySlots())
      return RestApiResponse.response($json, contentType="application/json")

  router.api(
    MethodGet,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Returns storage that is for sale

      without contracts =? node.contracts.host:
        return RestApiResponse.error(Http503, "Sales unavailable")

      without avails =? (await contracts.sales.context.reservations.all(Availability)), err:
        return RestApiResponse.error(Http500, err.msg)

      let json = %avails
      return RestApiResponse.response($json, contentType="application/json")

  router.rawApi(
    MethodPost,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Add available storage to sell
      ##
      ## size           - size of available storage in bytes
      ## duration       - maximum time the storage should be sold for (in seconds)
      ## minPrice       - minimum price to be paid (in amount of tokens)
      ## maxCollateral  - maximum collateral user is willing to pay per filled Slot (in amount of tokens)

      without contracts =? node.contracts.host:
        return RestApiResponse.error(Http503, "Sales unavailable")

      let body = await request.getBody()

      without restAv =? RestAvailability.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg)

      let reservations = contracts.sales.context.reservations

      if not reservations.hasAvailable(restAv.size.truncate(uint)):
        return RestApiResponse.error(Http422, "Not enough storage quota")

      without availability =? (
        await reservations.createAvailability(
          restAv.size,
          restAv.duration,
          restAv.minPrice,
          restAv.maxCollateral)
        ), error:
        return RestApiResponse.error(Http500, error.msg)

      return RestApiResponse.response(availability.toJson,
                                      contentType="application/json")

proc initPurchasingApi(node: CodexNodeRef, router: var RestRouter) =
  router.rawApi(
    MethodPost,
    "/api/codex/v1/storage/request/{cid}") do (cid: Cid) -> RestApiResponse:
      ## Create a request for storage
      ##
      ## cid              - the cid of a previously uploaded dataset
      ## duration         - the duration of the request in seconds
      ## proofProbability - how often storage proofs are required
      ## reward           - the maximum amount of tokens paid per second per slot to hosts the client is willing to pay
      ## expiry           - timestamp, in seconds, when the request expires if the Request does not find requested amount of nodes to host the data
      ## nodes            - minimal number of nodes the content should be stored on
      ## tolerance        - allowed number of nodes that can be lost before pronouncing the content lost
      ## colateral        - requested collateral from hosts when they fill slot

      without cid =? cid.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg)

      let body = await request.getBody()

      without params =? StorageRequestParams.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg)

      let nodes = params.nodes |? 1
      let tolerance = params.tolerance |? 0

      without purchaseId =? await node.requestStorage(
        cid,
        params.duration,
        params.proofProbability,
        nodes,
        tolerance,
        params.reward,
        params.collateral,
        params.expiry), error:

        return RestApiResponse.error(Http500, error.msg)

      return RestApiResponse.response(purchaseId.toHex)

  router.api(
    MethodGet,
    "/api/codex/v1/storage/purchases/{id}") do (
      id: PurchaseId) -> RestApiResponse:

      without contracts =? node.contracts.client:
        return RestApiResponse.error(Http503, "Purchasing unavailable")

      without id =? id.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg)

      without purchase =? contracts.purchasing.getPurchase(id):
        return RestApiResponse.error(Http404)

      let json = % RestPurchase(
        state: purchase.state |? "none",
        error: purchase.error.?msg,
        request: purchase.request,
        requestId: purchase.requestId
      )

      return RestApiResponse.response($json, contentType="application/json")

proc initDebugApi(node: CodexNodeRef, conf: CodexConf, router: var RestRouter) =
  router.api(
    MethodGet,
    "/api/codex/v1/debug/info") do () -> RestApiResponse:
      ## Print rudimentary node information
      ##

      let table = RestRoutingTable.init(node.discovery.protocol.routingTable)

      let
        json = %*{
          "id": $node.switch.peerInfo.peerId,
          "addrs": node.switch.peerInfo.addrs.mapIt( $it ),
          "repo": $conf.dataDir,
          "spr":
            if node.discovery.dhtRecord.isSome:
              node.discovery.dhtRecord.get.toURI
            else:
              "",
          "table": table,
          "codex": {
            "version": $codexVersion,
            "revision": $codexRevision
          }
        }

      return RestApiResponse.response($json, contentType="application/json")

  router.api(
    MethodPost,
    "/api/codex/v1/debug/chronicles/loglevel") do (
      level: Option[string]) -> RestApiResponse:
      ## Set log level at run time
      ##
      ## e.g. `chronicles/loglevel?level=DEBUG`
      ##
      ## `level` - chronicles log level
      ##

      without res =? level and level =? res:
        return RestApiResponse.error(Http400, "Missing log level")

      try:
        {.gcsafe.}:
          updateLogLevel(level)
      except CatchableError as exc:
        return RestApiResponse.error(Http500, exc.msg)

      return RestApiResponse.response("")

  when codex_enable_api_debug_peers:
    router.api(
      MethodGet,
      "/api/codex/v1/debug/peer/{peerId}") do (peerId: PeerId) -> RestApiResponse:

        trace "debug/peer start"
        without peerRecord =? (await node.findPeer(peerId.get())):
          trace "debug/peer peer not found!"
          return RestApiResponse.error(
            Http400,
            "Unable to find Peer!")

        let json = %RestPeerRecord.init(peerRecord)
        trace "debug/peer returning peer record"
        return RestApiResponse.response($json)

proc initRestApi*(node: CodexNodeRef, conf: CodexConf): RestRouter =
  var router = RestRouter.init(validate)

  initContentApi(node, router)
  initSalesApi(node, router)
  initPurchasingApi(node, router)
  initDebugApi(node, conf, router)

  router.api(
    MethodGet,
    "/api/codex/v1/connect/{peerId}") do (
      peerId: PeerId,
      addrs: seq[MultiAddress]) -> RestApiResponse:
      ## Connect to a peer
      ##
      ## If `addrs` param is supplied, it will be used to
      ## dial the peer, otherwise the `peerId` is used
      ## to invoke peer discovery, if it succeeds
      ## the returned addresses will be used to dial
      ##
      ## `addrs` the listening addresses of the peers to dial, eg the one specified with `--listen-addrs`
      ##

      if peerId.isErr:
        return RestApiResponse.error(
          Http400,
          $peerId.error())

      let addresses = if addrs.isOk and addrs.get().len > 0:
            addrs.get()
          else:
            without peerRecord =? (await node.findPeer(peerId.get())):
              return RestApiResponse.error(
                Http400,
                "Unable to find Peer!")
            peerRecord.addresses.mapIt(it.address)
      try:
        await node.connect(peerId.get(), addresses)
        return RestApiResponse.response("Successfully connected to peer")
      except DialFailedError:
        return RestApiResponse.error(Http400, "Unable to dial peer")
      except CatchableError:
        return RestApiResponse.error(Http400, "Unknown error dialling peer")

  return router
