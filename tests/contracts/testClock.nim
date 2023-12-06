import std/times
import pkg/chronos
import codex/contracts/clock
import codex/utils/json
import ../ethertest

ethersuite "On-Chain Clock":
  var clock: OnChainClock

  setup:
    clock = OnChainClock.new(provider)
    await clock.start()

  teardown:
    await clock.stop()

  test "returns the current time of the EVM":
    let latestBlock = (!await provider.getBlock(BlockTag.latest))
    let timestamp = latestBlock.timestamp.truncate(int64)
    check clock.now() == timestamp

  test "updates time with timestamp of new blocks":
    let future = (getTime() + 42.years).toUnix
    discard await provider.send("evm_setNextBlockTimestamp", @[%future])
    discard await provider.send("evm_mine")
    check clock.now() == future

  test "updates time using wall-clock in-between blocks":
    let past = clock.now()
    await sleepAsync(chronos.seconds(1))
    check clock.now() > past

  test "can wait until a certain time is reached by the chain":
    let future = clock.now() + 42 # seconds
    let waiting = clock.waitUntil(future)
    discard await provider.send("evm_setNextBlockTimestamp", @[%future])
    discard await provider.send("evm_mine")
    check await waiting.withTimeout(chronos.milliseconds(100))

  test "can wait until a certain time is reached by the wall-clock":
    let future = clock.now() + 1 # seconds
    let waiting = clock.waitUntil(future)
    check await waiting.withTimeout(chronos.seconds(2))

  test "raises when not started":
    expect AssertionDefect:
      discard OnChainClock.new(provider).now()

  test "raises when stopped":
    await clock.stop()
    expect AssertionDefect:
      discard clock.now()

  test "handles starting multiple times":
    await clock.start()
    await clock.start()

  test "handles stopping multiple times":
    await clock.stop()
    await clock.stop()
