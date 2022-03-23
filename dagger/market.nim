import pkg/chronos
import ./contracts/requests

export chronos
export requests

type
  Market* = ref object of RootObj

method requestStorage*(market: Market, request: StorageRequest) {.base, async.} =
  raiseAssert("not implemented")
