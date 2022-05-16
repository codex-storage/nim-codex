import std/times
import pkg/ethers
import pkg/chronos
import pkg/stint

type
  Clock* = ref object
    provider: Provider
    subscription: Subscription
    offset: int64
    started: bool
  SecondsSince1970* = int64

proc new*(_: type Clock, provider: Provider): Clock =
  Clock(provider: provider)

proc start*(clock: Clock) {.async.} =
  if clock.started:
    return
  clock.started = true

  proc onBlock(blck: Block) {.gcsafe, upraises:[].} =
    let blockTime = blck.timestamp.truncate(int64)
    let computerTime = getTime().toUnix
    clock.offset = blockTime - computerTime

  onBlock(!await clock.provider.getBlock(BlockTag.latest))

  clock.subscription = await clock.provider.subscribe(onBlock)

proc stop*(clock: Clock) {.async.} =
  if not clock.started:
    return
  clock.started = false

  await clock.subscription.unsubscribe()

proc now*(clock: Clock): SecondsSince1970 =
  doAssert clock.started, "clock should be started before calling now()"
  getTime().toUnix + clock.offset
