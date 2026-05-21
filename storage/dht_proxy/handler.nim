## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/chronos
import pkg/libp2p
import pkg/libp2p/cid
import pkg/libp2p/routing_record

import ../discovery
import ../logutils
import ./protocol

export protocol

logScope:
  topics = "storage dht-proxy server"

type DhtProxyProtocol* = ref object of LPProtocol
  discovery*: Discovery

proc handleFindProviders(
    self: DhtProxyProtocol, queryBytes: seq[byte]
): Future[LookupResponse] {.async: (raises: [CancelledError]).} =
  let
    cid = Cid.init(queryBytes).valueOr:
      warn "Invalid CID in lookup request"
      return
        LookupResponse(status: ResponseStatus.Error, errorKind: ErrorKind.InvalidCid)
    providers = (await self.discovery.findDirect(cid)).valueOr:
      warn "Direct lookup failed", cid, err = error.msg
      return LookupResponse(status: ResponseStatus.Error, errorKind: ErrorKind.Internal)

  if providers.len == 0:
    return LookupResponse(status: ResponseStatus.NotFound)

  var encoded = newSeqOfCap[seq[byte]](providers.len)
  for spr in providers:
    let bytes = spr.encode().valueOr:
      warn "Failed to encode SignedPeerRecord", err = error
      continue
    encoded.add(bytes)

  if encoded.len == 0:
    return LookupResponse(status: ResponseStatus.Error, errorKind: ErrorKind.Internal)

  let packed = packProviders(encoded, MaxLookupResponseBytes).valueOr:
    return LookupResponse(status: ResponseStatus.Error, errorKind: error)

  LookupResponse(status: ResponseStatus.Ok, providers: packed)

proc handleLookupRequest(
    self: DhtProxyProtocol, conn: Connection
) {.async: (raises: [CancelledError]).} =
  try:
    let
      reqBytes = await conn.readLp(MaxLookupRequestBytes)
      req = LookupRequest.decode(reqBytes).valueOr:
        warn "Failed to decode lookup request"
        await conn.writeLp(
          LookupResponse(
            status: ResponseStatus.Error, errorKind: ErrorKind.DecodeFailed
          ).encode()
        )
        return

    let resp =
      case req.queryType
      of FindProviders:
        await self.handleFindProviders(req.queryBytes)

    await conn.writeLp(resp.encode())
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    warn "Stream error", err = exc.msg
  except CatchableError as exc:
    warn "Handler error", err = exc.msg

proc new*(T: type DhtProxyProtocol, discovery: Discovery): DhtProxyProtocol =
  let self = DhtProxyProtocol(discovery: discovery)

  proc handler(
      conn: Connection, proto: string
  ): Future[void] {.async: (raises: [CancelledError]).} =
    try:
      await self.handleLookupRequest(conn)
    finally:
      await noCancel conn.close()

  self.handler = handler
  self.codec = DhtProxyCodec
  return self
