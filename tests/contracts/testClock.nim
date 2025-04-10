import std/times
import pkg/chronos
import codex/contracts/clock
import codex/utils/json
import ../ethertest

ethersuite "On-Chain Clock":
  var clock: OnChainClock

  setup:
    clock = OnChainClock.new(ethProvider)
    await clock.start()

  teardown:
    await clock.stop()

  test "returns the current time of the EVM":
    let latestBlock = (!await ethProvider.getBlock(BlockTag.latest))
    let timestamp = latestBlock.timestamp.truncate(int64)
    check clock.now() == timestamp

  test "updates time with timestamp of new blocks":
    let future = (getTime() + 42.years).toUnix
    discard await ethProvider.send("evm_setNextBlockTimestamp", @[%future])
    discard await ethProvider.send("evm_mine")

    # Ensure that state updates are sync with WS
    discard await ethProvider.getBlock(BlockTag.latest)

    check eventually clock.now() == future

  test "can wait until a certain time is reached by the chain":
    let future = clock.now() + 42 # seconds
    let waiting = clock.waitUntil(future)
    discard await ethProvider.send("evm_setNextBlockTimestamp", @[%future])
    discard await ethProvider.send("evm_mine")
    check await waiting.withTimeout(chronos.milliseconds(500))

  test "can wait until a certain time is reached by the wall-clock":
    let future = clock.now() + 1 # seconds
    let waiting = clock.waitUntil(future)
    check await waiting.withTimeout(chronos.seconds(2))

  test "handles starting multiple times":
    await clock.start()
    await clock.start()

  test "handles stopping multiple times":
    await clock.stop()
    await clock.stop()
