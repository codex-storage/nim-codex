import pkg/chronos
import ./contracts/requests
import ./contracts/offers

export chronos
export requests
export offers

type
  Market* = ref object of RootObj

method requestStorage*(market: Market, request: StorageRequest) {.base, async.} =
  raiseAssert("not implemented")
