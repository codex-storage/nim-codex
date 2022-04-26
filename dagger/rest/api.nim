## Nim-Dagger
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
import pkg/stew/base10
import pkg/confutils

import pkg/libp2p/routing_record

import ../node
import ../blocktype
import ../conf
import ../contracts

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
    of CidError.Incorrect: "Incorrect Cid"
    of CidError.Unsupported: "Unsupported Cid"
    of CidError.Overrun: "Overrun Cid"
    else: "Error parsing Cid"

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

proc initRestApi*(node: DaggerNodeRef, conf: DaggerConf): RestRouter =
  var router = RestRouter.init(validate)
  router.api(
    MethodGet,
    "/api/dagger/v1/connect/{peerId}") do (
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
    "/api/dagger/v1/download/{id}") do (
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

  router.api(
    MethodPost,
    "/api/dagger/v1/storage/request/{cid}") do (
      cid: Cid,
      ppb: Option[uint],
      duration: Option[Duration],
      nodes: Option[uint],
      loss: Option[uint],
      renew: Option[bool]) -> RestApiResponse:
      ## Create a request for storage
      ##
      ## Cid            - the cid of the previously uploaded dataset
      ## ppb            - the price per byte the client is willing to pay
      ## duration       - the duration of the contract
      ## nodeCount      - the total amount of the nodes storing the dataset, including `lossTolerance`
      ## lossTolerance  - the number of nodes losses the user is willing to tolerate
      ## autoRenew      - should the contract be autorenewed -
      ##                  will fail unless the user has enough funds lockedup
      ##

      var
        cid =
          if cid.isErr:
            return RestApiResponse.error(Http400, $cid.error())
          else:
            cid.get()

        ppb =
          if ppb.isNone:
            return RestApiResponse.error(Http400, "Missing ppb")
          else:
            if ppb.get().isErr:
              return RestApiResponse.error(Http500, $ppb.get().error)
            else:
              ppb.get().get()

        duration =
          if duration.isNone:
            return RestApiResponse.error(Http400, "Missing duration")
          else:
            if duration.get().isErr:
              return RestApiResponse.error(Http500, $duration.get().error)
            else:
              duration.get().get()

        nodes =
          if nodes.isNone:
            return RestApiResponse.error(Http400, "Missing node count")
          else:
            if nodes.get().isErr:
              return RestApiResponse.error(Http500, $nodes.get().error)
            else:
              nodes.get().get()

        loss =
          if loss.isNone:
            return RestApiResponse.error(Http400, "Missing loss tolerance")
          else:
            if loss.get().isErr:
              return RestApiResponse.error(Http500, $loss.get().error)
            else:
              loss.get().get()

        renew = if renew.isNone:
            false
          else:
            if renew.get().isErr:
              return RestApiResponse.error(Http500, $renew.get().error)
            else:
              renew.get().get()

      try:
        without storageCid =? (await node.requestStorage(
            cid,
            ppb,
            duration,
            nodes,
            loss,
            renew)), error:
          return RestApiResponse.error(Http500, error.msg)

        return RestApiResponse.response($storageCid)
      except CatchableError as exc:
        return RestApiResponse.error(Http500, exc.msg)

  router.rawApi(
    MethodPost,
    "/api/dagger/v1/upload") do (
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
        stream = BufferStream.new()
        storeFut = node.store(stream)

      var bytes = 0
      try:
        while not reader.atEof:
          var
            buff = newSeqUninitialized[byte](BlockSize)
            len = await reader.readOnce(addr buff[0], buff.len)

          buff.setLen(len)
          if len <= 0:
            break

          trace "Got chunk from endpoint", len = buff.len
          await stream.pushData(buff)
          bytes += len

        await stream.pushEof()
        without cid =? (await storeFut), error:
          return RestApiResponse.error(Http500, error.msg)

        trace "Uploaded file", bytes, cid = $cid
        return RestApiResponse.response($cid)
      except CancelledError as exc:
        await reader.closeWait()
        return RestApiResponse.error(Http500)
      except AsyncStreamError:
        await reader.closeWait()
        return RestApiResponse.error(Http500)
      finally:
        await stream.close()
        await reader.closeWait()

      # if we got here something went wrong?
      return RestApiResponse.error(Http500)

  router.api(
    MethodGet,
    "/api/dagger/v1/info") do () -> RestApiResponse:
      ## Print rudimentary node information
      ##

      var addrs: string
      for a in node.switch.peerInfo.addrs:
        addrs &= "- " & $a & "\n"

      return RestApiResponse.response(
        "Id: " & $node.switch.peerInfo.peerId &
        "\nAddrs: \n" & addrs &
        "\nRoot Dir: " & $conf.dataDir)

  router.api(
    MethodGet,
    "/api/dagger/v1/sales/availability") do (
      size: Option[uint64],
      duration: Option[uint64],
      minPrice: Option[UInt256]) -> RestApiResponse:
      ## Add available storage to sell
      ##
      ## size       - size of available storage in bytes
      ## duration   - maximum time the storage should be sold for (in seconds)
      ## minPrice   - minimum price to be paid (in amount of tokens)

      without size =? size.?get():
        return RestApiResponse.error(Http400, "Missing or incorrect size")

      without duration =? duration.?get():
        return RestApiResponse.error(Http400, "Missing or incorrect duration")

      without minPrice =? minPrice.?get():
        return RestApiResponse.error(Http400, "Missing or incorrect minPrice")

      without contracts =? node.contracts:
        return RestApiResponse.error(Http503, "Sales unavailable")

      let availability = Availability.init(size, duration, minPrice)
      contracts.sales.add(availability)
      return RestApiResponse.response(availability.id.toHex)

  return router
