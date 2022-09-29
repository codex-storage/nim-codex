import std/times
import pkg/ethers
import pkg/chronos
import pkg/stint
import ../clock

export clock

type
  OnChainClock* = ref object of Clock
    provider: Provider
    subscription: Subscription
    offset: float
    started: bool

proc new*(_: type OnChainClock, provider: Provider): OnChainClock =
  OnChainClock(provider: provider)

proc start*(clock: OnChainClock) {.async.} =
  if clock.started:
    return
  clock.started = true

  proc onBlock(blck: Block) {.async, upraises:[].} =
    let blockTime = blck.timestamp.truncate(int64).float
    let computerTime = epochTime()
    clock.offset = blockTime - computerTime

  if latestBlock =? (await clock.provider.getBlock(BlockTag.latest)):
    await onBlock(latestBlock)

  clock.subscription = await clock.provider.subscribe(onBlock)

proc stop*(clock: OnChainClock) {.async.} =
  if not clock.started:
    return
  clock.started = false

  await clock.subscription.unsubscribe()

method now*(clock: OnChainClock): SecondsSince1970 =
  doAssert clock.started, "clock should be started before calling now()"
  int64(epochTime() + clock.offset)
