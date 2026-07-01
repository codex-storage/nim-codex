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
import pkg/libp2p/protobuf/minprotobuf
import pkg/libp2p_mix
import pkg/libp2p/routing_record
import pkg/stew/objects

import ../logutils

const DhtProxyCodec* = "/storage/dht-proxy/1.0.0"

const DefaultMaxInFlightLookups* = 100
const DhtProxyRequestReadTimeout* = 5.seconds

let MaxLookupRequestBytes* = getMaxMessageSizeForCodec(DhtProxyCodec, 1).expect(
    "DhtProxyCodec framing leaves no room for a Sphinx forward payload"
  )

let MaxLookupResponseBytes* = getMaxMessageSizeForCodec(DhtProxyCodec, 0).expect(
    "DhtProxyCodec framing leaves no room for a Sphinx reply payload"
  )

type
  QueryType* {.pure.} = enum
    FindProviders = 0

  LookupCode* {.pure.} = enum
    Ok = 0
    NotFound = 1
    ErrDecodeFailed = 100
    ErrInvalidCid = 101
    ErrInternal = 200
    ErrResponseTooLarge = 201
    ErrTooBusy = 202

  LookupRequest* = object
    queryType*: QueryType
    queryBytes*: seq[byte]

  LookupResponse* = object
    code*: LookupCode
    providers*: seq[seq[byte]]

proc encode*(req: LookupRequest): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, req.queryType.uint32)
  pb.write(2, req.queryBytes)
  pb.finish()
  pb.buffer

proc encode*(resp: LookupResponse): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, resp.code.uint32)
  for spr in resp.providers:
    pb.write(2, spr)
  pb.finish()
  pb.buffer

proc decode*(_: type LookupRequest, data: openArray[byte]): ProtoResult[LookupRequest] =
  let pb = initProtoBuffer(data)
  var
    req = LookupRequest()
    qt: uint32

  if ?pb.getField(1, qt):
    if not checkedEnumAssign(req.queryType, qt):
      return err(ProtoError.IncorrectBlob)

  discard ?pb.getField(2, req.queryBytes)
  ok(req)

proc decode*(
    _: type LookupResponse, data: openArray[byte]
): ProtoResult[LookupResponse] =
  let pb = initProtoBuffer(data)
  var
    resp = LookupResponse()
    codeOrd: uint32

  if ?pb.getField(1, codeOrd):
    if not checkedEnumAssign(resp.code, codeOrd):
      return err(ProtoError.IncorrectBlob)

  discard ?pb.getRepeatedField(2, resp.providers)
  ok(resp)

proc packProviders*(
    providers: seq[seq[byte]], budget_bytes: int
): Result[seq[seq[byte]], LookupCode] =
  if providers.len == 0:
    error "packProviders called with no providers"
    return err(LookupCode.ErrInternal)

  let single = LookupResponse(code: LookupCode.Ok, providers: providers[0 ..< 1])
  if single.encode().len > budget_bytes:
    return err(LookupCode.ErrResponseTooLarge)

  var
    lo = 1
    hi = providers.len
  while lo < hi:
    let
      mid = (lo + hi + 1) div 2
      test = LookupResponse(code: LookupCode.Ok, providers: providers[0 ..< mid])
    if test.encode().len <= budget_bytes:
      lo = mid
    else:
      hi = mid - 1

  ok(providers[0 ..< lo])
