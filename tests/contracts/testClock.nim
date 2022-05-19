import std/times
import pkg/chronos
import codex/contracts/clock
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

  test "raises when not started":
    expect AssertionError:
      discard OnChainClock.new(provider).now()

  test "raises when stopped":
    await clock.stop()
    expect AssertionError:
      discard clock.now()

  test "handles starting multiple times":
    await clock.start()
    await clock.start()

  test "handles stopping multiple times":
    await clock.stop()
    await clock.stop()
