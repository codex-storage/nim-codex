## Nim-Dagger
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/sequtils

import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos
import pkg/presto
import pkg/libp2p

import pkg/libp2p/routing_record

import ../node

proc validate(
  pattern: string,
  value: string): int
  {.gcsafe, raises: [Defect].} =
  0

proc encodeString(cid: type Cid): Result[string, cstring] =
  ok($cid)

proc decodeString(T: type Cid, value: string): Result[Cid, cstring] =
  Cid.init(value)
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

proc initRestApi*(node: DaggerNodeRef): RestRouter =
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
            let peerRecord = await node.findPeer(peerId.get())
            if peerRecord.isErr:
              return RestApiResponse.error(
                Http400,
                "Unable to find Peer!")

            peerRecord.get().addresses.mapIt(
              it.address
            )
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

      let
        stream = BufferStream.new()

      var bytes = 0
      try:
        if (
            let retr = await node.retrieve(stream, id.get());
            retr.isErr):
            return RestApiResponse.error(Http404, retr.error.msg)

        resp.addHeader("Content-Type", "application/octet-stream")
        await resp.prepareChunked()
        while not stream.atEof:
          var
            buff = newSeqUninitialized[byte](FileChunkSize)
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
        await stream.close()

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
            buff = newSeqUninitialized[byte](FileChunkSize)
            len = await reader.readOnce(addr buff[0], buff.len)

          buff.setLen(len)
          if len <= 0:
            break

          trace "Got chunk from endpoint", len = buff.len
          await stream.pushData(buff)
          bytes += len

        await stream.pushEof()
        without cid =? (await storeFut):
          return RestApiResponse.error(Http500)

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
        "\nAddrs: \n" & addrs & "\n")

  return router
