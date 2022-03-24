import pkg/dagger/market

type
  MockMarket* = ref object of Market
    requested*: seq[StorageRequest]

method requestStorage*(market: MockMarket, request: StorageRequest) {.async.} =
  market.requested.add(request)
