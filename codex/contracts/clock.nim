import std/times
import pkg/ethers
import pkg/chronos
import pkg/stint
import ../clock

export clock

logScope:
  topics = "contracts clock"

type
  LastBlockUnknownError* = object of CatchableError
  OnChainClock* = ref object of Clock
    provider: Provider
    subscription: Subscription
    offset: times.Duration
    started: bool
    newBlock: AsyncEvent

proc new*(_: type OnChainClock, provider: Provider): OnChainClock =
  OnChainClock(provider: provider, newBlock: newAsyncEvent())

method start*(clock: OnChainClock) {.async.} =
  if clock.started:
    return
  trace "starting on chain clock"
  clock.started = true

  proc onBlock(blck: Block) {.upraises:[].} =
    let blockTime = initTime(blck.timestamp.truncate(int64), 0)
    let computerTime = getTime()
    clock.offset = blockTime - computerTime
    trace "new block received, updated clock offset", blockTime, computerTime, offset = clock.offset
    clock.newBlock.fire()

  if latestBlock =? (await clock.provider.getBlock(BlockTag.latest)):
    onBlock(latestBlock)

  clock.subscription = await clock.provider.subscribe(onBlock)

method stop*(clock: OnChainClock) {.async.} =
  if not clock.started:
    return
  trace "stopping on chain clock"
  clock.started = false

  await clock.subscription.unsubscribe()

method now*(clock: OnChainClock): SecondsSince1970 =
  doAssert clock.started, "clock should be started before calling now()"
  toUnix(getTime() + clock.offset)

method lastBlockTimestamp*(clock: OnChainClock): Future[UInt256] {.async.} =
  without blk =? await clock.provider.getBlock(BlockTag.latest):
    raise newException(LastBlockUnknownError, "failed to get last block")

  return blk.timestamp

method waitUntil*(clock: OnChainClock, time: SecondsSince1970) {.async.} =
  trace "waiting until", time
  while (let difference = time - (await clock.lastBlockTimestamp).truncate(int64); difference > 0):
    clock.newBlock.clear()
    discard await clock.newBlock.wait().withTimeout(chronos.seconds(difference))
  trace "waiting for time unblocked"
