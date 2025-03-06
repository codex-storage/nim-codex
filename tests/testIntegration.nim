import std/os
import std/strformat
import std/terminal
from std/times import format, now
import std/terminal
import std/typetraits
import pkg/chronos
import pkg/codex/conf
import pkg/codex/logutils
import ./integration/testmanager
import ./integration/utils

{.warning[UnusedImport]: off.}
{.push raises: [].}

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

# Echoes stdout from Hardhat process
const DebugHardhat {.booldefine.} = false
# Echoes stdout from the integration test file process. Codex process logs can
# also be output if a test uses a multinodesuite, requires CodexConfig.debug
# to be enabled
const DebugCodexNodes {.booldefine.} = false
# Shows test status updates at time intervals. Useful for running locally with
# active terminal interaction. Set to false for unattended runs, eg CI.
const ShowContinuousStatusUpdates {.booldefine.} = false
# Timeout duration (in minutes) for EACH integration test file.
const TestTimeout {.intdefine.} = 60

const EnableParallelTests {.booldefine.} = true

proc setupLogging(logFile: string) =
  try:
    let success = defaultChroniclesStream.outputs[0].open(logFile, fmAppend)
    doAssert success, "Failed to open log file: " & logFile
  except IOError, OSError:
    let error = getCurrentException()
    fatal "Failed to open log file", error = error.msg
    raiseAssert "Could not open test manager log file: " & error.msg

proc run(): Future[bool] {.async: (raises: []).} =
  let startTime = now().format("yyyy-MM-dd'_'HH-mm-ss")
  let logsDir =
    currentSourcePath.parentDir() / "integration" / "logs" /
    sanitize(startTime & "-IntegrationTests")
  try:
    createDir(logsDir)
    #!fmt: off
    styledEcho bgWhite, fgBlack, styleBright,
      "\n\n  ",
      styleUnderscore,
      "ℹ️  LOGS AVAILABLE ℹ️\n\n",
      resetStyle, bgWhite, fgBlack, styleBright,
      """  Logs for this run will be available at:""",
      resetStyle, bgWhite, fgBlack,
      &"\n\n  {logsDir}\n\n",
      resetStyle, bgWhite, fgBlack, styleBright,
      "  NOTE: For CI runs, logs will be attached as artefacts\n"
      #!fmt: on
  except IOError as e:
    raiseAssert "Failed to create log directory and echo log message: " & e.msg
  except OSError as e:
    raiseAssert "Failed to create log directory and echo log message: " & e.msg

  setupLogging(TestManager.logFile(logsDir))

  let manager = TestManager.new(
    config = TestManagerConfig(
      debugHardhat: DebugHardhat,
      debugCodexNodes: DebugCodexNodes,
      showContinuousStatusUpdates: ShowContinuousStatusUpdates,
      logsDir: logsDir,
      testTimeout: TestTimeout.minutes,
    ),
    testConfigs = TestConfigs,
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
