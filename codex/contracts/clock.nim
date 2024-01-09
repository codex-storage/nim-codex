import std/times
import pkg/ethers
import pkg/chronos
import pkg/stint
import ../clock
import ../conf

export clock

logScope:
  topics = "contracts clock"

type
  OnChainClock* = ref object of Clock
    provider: Provider
    subscription: Subscription
    offset: times.Duration
    started: bool
    newBlock: AsyncEvent
    lastBlockTime: UInt256

proc new*(_: type OnChainClock, provider: Provider): OnChainClock =
  OnChainClock(provider: provider, newBlock: newAsyncEvent())

method start*(clock: OnChainClock) {.async.} =
  if clock.started:
    return

  proc onBlock(blck: Block) =
    let blockTime = initTime(blck.timestamp.truncate(int64), 0)
    let computerTime = getTime()
    clock.offset = blockTime - computerTime
    clock.lastBlockTime = blck.timestamp
    clock.newBlock.fire()

  if latestBlock =? (await clock.provider.getBlock(BlockTag.latest)):
    onBlock(latestBlock)

  clock.subscription = await clock.provider.subscribe(onBlock)
  clock.started = true

method stop*(clock: OnChainClock) {.async.} =
  if not clock.started:
    return

  await clock.subscription.unsubscribe()
  clock.started = false

method now*(clock: OnChainClock): SecondsSince1970 =
  when codex_use_hardhat:
    # hardhat's latest block.timestamp is usually 1s behind the block timestamp
    # in the newHeads event. When testing, always return the latest block.
    try:
      if queriedBlock =? (waitFor clock.provider.getBlock(BlockTag.latest)):
        trace "using last block timestamp for clock.now",
          lastBlockTimestamp = queriedBlock.timestamp.truncate(int64),
          cachedBlockTimestamp = clock.lastBlockTime.truncate(int64)
        return queriedBlock.timestamp.truncate(int64)
    except CatchableError as e:
      warn "failed to get latest block timestamp", error = e.msg
      return clock.lastBlockTime.truncate(int64)

  else:
    doAssert clock.started, "clock should be started before calling now()"
    return toUnix(getTime() + clock.offset)

method waitUntil*(clock: OnChainClock, time: SecondsSince1970) {.async.} =
  while (let difference = time - clock.now(); difference > 0):
    clock.newBlock.clear()
    discard await clock.newBlock.wait().withTimeout(chronos.seconds(difference))
