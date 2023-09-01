import pkg/questionable
import pkg/questionable/results
import pkg/stew/byteutils
import ../sales
import ../purchasing
import ../utils/json

export json

type
  StorageRequestParams* = object
    duration* {.serialize.}: UInt256
    proofProbability* {.serialize.}: UInt256
    reward* {.serialize.}: UInt256
    collateral* {.serialize.}: UInt256
    expiry* {.serialize.}: ?UInt256
    nodes* {.serialize.}: ?uint
    tolerance* {.serialize.}: ?uint

  RestPurchase* = object
    requestId* {.serialize.}: RequestId
    request* {.serialize.}: ?StorageRequest
    state* {.serialize.}: string
    error* {.serialize.}: ?string

  RestAvailability* = object
    size* {.serialize.}: UInt256
    duration* {.serialize.}: UInt256
    minPrice* {.serialize.}: UInt256
    maxCollateral* {.serialize.}: UInt256

func `%`*(obj: StorageRequest | Slot): JsonNode =
  let jsonObj = newJObject()
  for k, v in obj.fieldPairs: jsonObj[k] = %v
  jsonObj["id"] = %(obj.id)

  return jsonObj
