## Logos Storage
## Copyright (c) 2026 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p_mix
import pkg/libp2p/routing_record

import ../logutils

const DhtProxyCodec* = "/storage/dht-proxy/1.0.0"

const DefaultMaxInFlightLookups* = 100

let MaxLookupRequestBytes* = getMaxMessageSizeForCodec(DhtProxyCodec, 1).expect(
    "DhtProxyCodec framing leaves no room for a Sphinx forward payload"
  )

let MaxLookupResponseBytes* = getMaxMessageSizeForCodec(DhtProxyCodec, 0).expect(
    "DhtProxyCodec framing leaves no room for a Sphinx reply payload"
  )

type
  QueryType* {.pure.} = enum
    FindProviders = 0

  ResponseStatus* {.pure.} = enum
    Ok = 0
    NotFound = 1
    Error = 2

  ErrorKind* {.pure.} = enum
    DecodeFailed = 0
    InvalidCid = 1
    Internal = 2
    ResponseTooLarge = 3
    TooBusy = 4

  LookupRequest* = object
    queryType*: QueryType
    queryBytes*: seq[byte]

  LookupResponse* = object
    status*: ResponseStatus
    errorKind*: ErrorKind
    providers*: seq[seq[byte]]

proc encode*(req: LookupRequest): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, req.queryType.uint32)
  pb.write(2, req.queryBytes)
  pb.finish()
  pb.buffer

proc encode*(resp: LookupResponse): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, resp.status.uint32)
  if resp.status == ResponseStatus.Error:
    pb.write(2, resp.errorKind.uint32)
  for spr in resp.providers:
    pb.write(3, spr)
  pb.finish()
  pb.buffer

proc decode*(_: type LookupRequest, data: openArray[byte]): ProtoResult[LookupRequest] =
  let pb = initProtoBuffer(data)
  var
    req = LookupRequest()
    qt: uint32

  if ?pb.getField(1, qt):
    if qt > QueryType.high.uint32:
      return err(ProtoError.IncorrectBlob)
    req.queryType = QueryType(qt)

  discard ?pb.getField(2, req.queryBytes)
  ok(req)

proc decode*(
    _: type LookupResponse, data: openArray[byte]
): ProtoResult[LookupResponse] =
  let pb = initProtoBuffer(data)
  var
    resp = LookupResponse()
    status: uint32

  if ?pb.getField(1, status):
    if status > ResponseStatus.high.uint32:
      return err(ProtoError.IncorrectBlob)
    resp.status = ResponseStatus(status)

  if resp.status == ResponseStatus.Error:
    var ek: uint32
    if ?pb.getField(2, ek):
      if ek > ErrorKind.high.uint32:
        return err(ProtoError.IncorrectBlob)
      resp.errorKind = ErrorKind(ek)

  discard ?pb.getRepeatedField(3, resp.providers)

  ok(resp)

proc packProviders*(
    providers: seq[seq[byte]], budget_bytes: int
): Result[seq[seq[byte]], ErrorKind] =
  if providers.len == 0:
    error "packProviders called with no providers"
    return err(ErrorKind.Internal)

  let single = LookupResponse(status: ResponseStatus.Ok, providers: providers[0 ..< 1])
  if single.encode().len > budget_bytes:
    return err(ErrorKind.ResponseTooLarge)

  var
    lo = 1
    hi = providers.len
  while lo < hi:
    let
      mid = (lo + hi + 1) div 2
      test = LookupResponse(status: ResponseStatus.Ok, providers: providers[0 ..< mid])
    if test.encode().len <= budget_bytes:
      lo = mid
    else:
      hi = mid - 1

  ok(providers[0 ..< lo])
