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
    started: bool
    newBlock: AsyncEvent
    lastBlockTime: UInt256

proc new*(_: type OnChainClock, provider: Provider): OnChainClock =
  OnChainClock(provider: provider, newBlock: newAsyncEvent())

method start*(clock: OnChainClock) {.async.} =
  if clock.started:
    return
  clock.started = true

  proc onBlock(blck: Block) {.upraises:[].} =
    clock.lastBlockTime = blck.timestamp
    clock.newBlock.fire()

  if latestBlock =? (await clock.provider.getBlock(BlockTag.latest)):
    onBlock(latestBlock)

  clock.subscription = await clock.provider.subscribe(onBlock)

method stop*(clock: OnChainClock) {.async.} =
  if not clock.started:
    return
  clock.started = false

  await clock.subscription.unsubscribe()

method now*(clock: OnChainClock): SecondsSince1970 =
  when codex_testing:
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
    trace "using cached block timestamp (newHeads) for clock.now",
      timestamp = clock.lastBlockTime.truncate(int64)
    return clock.lastBlockTime.truncate(int64)

method waitUntil*(clock: OnChainClock, time: SecondsSince1970) {.async.} =
  while (let difference = time - clock.now(); difference > 0):
    clock.newBlock.clear()
    discard await clock.newBlock.wait().withTimeout(chronos.seconds(difference))
