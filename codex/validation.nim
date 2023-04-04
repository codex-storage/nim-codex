import pkg/chronos
import ./market
import ./clock

export market

type
  Validation* = ref object
    clock: Clock
    market: Market

proc new*(_: type Validation, clock: Clock, market: Market): Validation =
  Validation(clock: clock, market: market)

proc start*(validation: Validation) {.async.} =
  discard # TODO

proc stop*(validation: Validation) {.async.} =
  discard # TODO
