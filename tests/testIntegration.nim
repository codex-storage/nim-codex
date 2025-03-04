import std/terminal
import pkg/chronos
import pkg/codex/logutils
import ./integration/testmanager

{.warning[UnusedImport]: off.}

const TestConfigs =
  @[
    IntegrationTestConfig.init("./integration/testcli", startHardhat = true),
    IntegrationTestConfig.init("./integration/testrestapi", startHardhat = true),
    IntegrationTestConfig.init("./integration/testupdownload", startHardhat = true),
    IntegrationTestConfig.init("./integration/testsales", startHardhat = true),
    IntegrationTestConfig.init("./integration/testpurchasing", startHardhat = true),
    IntegrationTestConfig.init("./integration/testblockexpiration", startHardhat = true),
    IntegrationTestConfig.init("./integration/testmarketplace", startHardhat = true),
    IntegrationTestConfig.init("./integration/testproofs", startHardhat = true),
    IntegrationTestConfig.init("./integration/testvalidator", startHardhat = true),
    IntegrationTestConfig.init("./integration/testecbug", startHardhat = true),
    IntegrationTestConfig.init(
      "./integration/testrestapivalidation", startHardhat = true
    ),
  ]

# Echoes stderr if there's a test failure (eg test failed, compilation error)
# or error (eg test manager error)
const DebugTestHarness {.booldefine.} = false
# Echoes stdout from Hardhat process
const DebugHardhat {.booldefine.} = false
# Echoes stdout from the integration test file process. Codex process logs can
# also be output if a test uses a multinodesuite, requires CodexConfig.debug
# to be enabled
const DebugCodexNodes {.booldefine.} = false
# Shows test status updates at time intervals. Useful for running locally with
# active terminal interaction. Set to false for unattended runs, eg CI.
const ShowContinuousStatusUpdates {.booldefine.} = false
# Timeout duration (in mimutes) for EACH integration test file.
const TestTimeout {.intdefine.} = 60

const EnableParallelTests {.booldefine.} = true

proc run(): Future[bool] {.async: (raises: []).} =
  let manager = TestManager.new(
    configs = TestConfigs,
    DebugTestHarness,
    DebugHardhat,
    DebugCodexNodes,
    ShowContinuousStatusUpdates,
    TestTimeout.minutes,
  )
  try:
    trace "starting test manager"
    await manager.start()
  except TestManagerError as e:
    error "Failed to run test manager", error = e.msg
    return false
  except CancelledError:
    return false
  finally:
    trace "Stopping test manager"
    await manager.stop()
    trace "Test manager stopped"

  without wasSuccessful =? manager.allTestsPassed, error:
    raiseAssert "Failed to get test status: " & error.msg

  return wasSuccessful

when isMainModule:
  when EnableParallelTests:
    let wasSuccessful = waitFor run()
    if wasSuccessful:
      quit(QuitSuccess)
    else:
      quit(QuitFailure) # indicate with a non-zero exit code that the tests failed
  else:
    # run tests serially
    import ./integration/testcli
    import ./integration/testrestapi
    import ./integration/testupdownload
    import ./integration/testsales
    import ./integration/testpurchasing
    import ./integration/testblockexpiration
    import ./integration/testmarketplace
    import ./integration/testproofs
    import ./integration/testvalidator
    import ./integration/testecbug
