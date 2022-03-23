import pkg/dagger/market

type
  MockMarket* = ref object of Market
    requests*: seq[StorageRequest]

method requestStorage*(market: MockMarket, request: StorageRequest) {.async.} =
  market.requests.add(request)
