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
import std/sugar

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p
import pkg/stew/base10
import pkg/stew/byteutils
import pkg/confutils

import pkg/libp2p/routing_record
import pkg/libp2pdht/discv5/spr as spr

import ../node
import ../blocktype
import ../conf
import ../contracts
import ../streams

import ./json

proc validate(
  pattern: string,
  value: string): int
  {.gcsafe, raises: [Defect].} =
  0

proc encodeString(cid: type Cid): Result[string, cstring] =
  ok($cid)

proc decodeString(T: type Cid, value: string): Result[Cid, cstring] =
  Cid
  .init(value)
  .mapErr do(e: CidError) -> cstring:
    case e
    of CidError.Incorrect: "Incorrect Cid".cstring
    of CidError.Unsupported: "Unsupported Cid".cstring
    of CidError.Overrun: "Overrun Cid".cstring
    else: "Error parsing Cid".cstring

proc encodeString(peerId: PeerID): Result[string, cstring] =
  ok($peerId)

proc decodeString(T: type PeerID, value: string): Result[PeerID, cstring] =
  PeerID.init(value)

proc encodeString(address: MultiAddress): Result[string, cstring] =
  ok($address)

proc decodeString(T: type MultiAddress, value: string): Result[MultiAddress, cstring] =
  MultiAddress
    .init(value)
    .mapErr do(e: string) -> cstring: cstring(e)

proc decodeString(T: type SomeUnsignedInt, value: string): Result[T, cstring] =
  Base10.decode(T, value)

proc encodeString(value: SomeUnsignedInt): Result[string, cstring] =
  ok(Base10.toString(value))

proc decodeString(T: type Duration, value: string): Result[T, cstring] =
  let v = ? Base10.decode(uint32, value)
  ok(v.minutes)

proc encodeString(value: Duration): Result[string, cstring] =
  ok($value)

proc decodeString(T: type bool, value: string): Result[T, cstring] =
  try:
    ok(value.parseBool())
  except CatchableError as exc:
    let s: cstring = exc.msg
    err(s) # err(exc.msg) won't compile

proc encodeString(value: bool): Result[string, cstring] =
  ok($value)

proc decodeString(_: type UInt256, value: string): Result[UInt256, cstring] =
  try:
    ok UInt256.fromHex(value)
  except ValueError as e:
    err e.msg.cstring

proc decodeString(_: type array[32, byte],
                  value: string): Result[array[32, byte], cstring] =
  try:
    ok array[32, byte].fromHex(value)
  except ValueError as e:
    err e.msg.cstring

proc decodeString[T: PurchaseId | RequestId | Nonce](_: type T,
                  value: string): Result[T, cstring] =
  array[32, byte].decodeString(value).map(id => T(id))

proc initRestApi*(node: CodexNodeRef, conf: CodexConf): RestRouter =
  var router = RestRouter.init(validate)
  router.api(
    MethodGet,
    "/api/codex/v1/connect/{peerId}") do (
      peerId: PeerID,
      addrs: seq[MultiAddress]) -> RestApiResponse:
      ## Connect to a peer
      ##
      ## If `addrs` param is supplied, it will be used to
      ## dial the peer, otherwise the `peerId` is used
      ## to invoke peer discovery, if it succeeds
      ## the returned addresses will be used to dial
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
      except DialFailedError as e:
        return RestApiResponse.error(Http400, "Unable to dial peer")
      except CatchableError as e:
        return RestApiResponse.error(Http400, "Unknown error dialling peer")

  router.api(
    MethodGet,
    "/api/codex/v1/download/{id}") do (
      id: Cid, resp: HttpResponseRef) -> RestApiResponse:
      ## Download a file from the node in a streaming
      ## manner
      ##

      if id.isErr:
        return RestApiResponse.error(
          Http400,
          $id.error())

      var
        stream: LPStream

      var bytes = 0
      try:
        without stream =? (await node.retrieve(id.get())), error:
          return RestApiResponse.error(Http404, error.msg)

        resp.addHeader("Content-Type", "application/octet-stream")
        await resp.prepareChunked()

        while not stream.atEof:
          var
            buff = newSeqUninitialized[byte](BlockSize)
            len = await stream.readOnce(addr buff[0], buff.len)

          buff.setLen(len)
          if buff.len <= 0:
            break

          bytes += buff.len
          trace "Sending chunk", size = buff.len
          await resp.sendChunk(addr buff[0], buff.len)
        await resp.finish()
      except CatchableError as exc:
        trace "Excepting streaming blocks", exc = exc.msg
        return RestApiResponse.error(Http500)
      finally:
        trace "Sent bytes", cid = id.get(), bytes
        if not stream.isNil:
          await stream.close()

  router.rawApi(
    MethodPost,
    "/api/codex/v1/storage/request/{cid}") do (cid: Cid) -> RestApiResponse:
      ## Create a request for storage
      ##
      ## cid            - the cid of a previously uploaded dataset
      ## duration       - the duration of the contract
      ## reward       - the maximum price the client is willing to pay

      without cid =? cid.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg)

      let body = await request.getBody()

      without params =? StorageRequestParams.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg)

      let nodes = params.nodes |? 1
      let tolerance = params.nodes |? 0

      without purchaseId =? await node.requestStorage(cid,
                                                      params.duration,
                                                      nodes,
                                                      tolerance,
                                                      params.reward,
                                                      params.expiry), error:
        return RestApiResponse.error(Http500, error.msg)

      return RestApiResponse.response(purchaseId.toHex)

  router.rawApi(
    MethodPost,
    "/api/codex/v1/upload") do (
    ) -> RestApiResponse:
      ## Upload a file in a streamming manner
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

        trace "Uploaded file", cid = $cid
        return RestApiResponse.response($cid)
      except CancelledError as exc:
        return RestApiResponse.error(Http500)
      except AsyncStreamError:
        return RestApiResponse.error(Http500)
      finally:
        await reader.closeWait()

      # if we got here something went wrong?
      return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/codex/v1/info") do () -> RestApiResponse:
      ## Print rudimentary node information
      ##

      let json = %*{
        "id": $node.switch.peerInfo.peerId,
        "addrs": node.switch.peerInfo.addrs.mapIt( $it ),
        "repo": $conf.dataDir,
        "spr": node.switch.peerInfo.signedPeerRecord.toURI
      }

      return RestApiResponse.response($json)

  router.api(
    MethodGet,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Returns storage that is for sale

      without contracts =? node.contracts:
        return RestApiResponse.error(Http503, "Sales unavailable")

      let json = %contracts.sales.available
      return RestApiResponse.response($json)

  router.rawApi(
    MethodPost,
    "/api/codex/v1/sales/availability") do () -> RestApiResponse:
      ## Add available storage to sell
      ##
      ## size       - size of available storage in bytes
      ## duration   - maximum time the storage should be sold for (in seconds)
      ## minPrice   - minimum price to be paid (in amount of tokens)

      without contracts =? node.contracts:
        return RestApiResponse.error(Http503, "Sales unavailable")

      let body = await request.getBody()

      without availability =? Availability.fromJson(body), error:
        return RestApiResponse.error(Http400, error.msg)

      contracts.sales.add(availability)

      let json = %availability
      return RestApiResponse.response($json)

  router.api(
    MethodGet,
    "/api/codex/v1/storage/purchases/{id}") do (
      id: PurchaseId) -> RestApiResponse:

      without contracts =? node.contracts:
        return RestApiResponse.error(Http503, "Purchasing unavailable")

      without id =? id.tryGet.catch, error:
        return RestApiResponse.error(Http400, error.msg)

      without purchase =? contracts.purchasing.getPurchase(id):
        return RestApiResponse.error(Http404)

      let json = %purchase

      return RestApiResponse.response($json)


  return router
