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
# Timeout duration (in minutes) for EACH integration test file.
const TestTimeout {.intdefine.} = 60

const EnableParallelTests {.booldefine.} = true

proc setupLogging(logFile: string, debugTestHarness: bool) =
  when defaultChroniclesStream.outputs.type.arity != 3:
    raiseAssert "Logging configuration options not enabled in the current build"
  else:
    proc writeAndFlush(f: File, msg: LogOutputStr) =
      try:
        f.write(msg)
        f.flushFile()
      except IOError as err:
        logLoggingFailure(cstring(msg), err)

    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
      writeAndFlush(stdout, msg)

    proc fileFlush(logLevel: LogLevel, msg: LogOutputStr) =
      try:
        logFile.appendFile(stripAnsi(msg))
      except IOError as error:
        fatal "Failed to write to log file", error = error.msg # error = error.ioErrorMsg
        raiseAssert "Could not write to test manager log file: " & error.msg

    defaultChroniclesStream.outputs[0].writer = stdoutFlush
    defaultChroniclesStream.outputs[1].writer = noOutput
    if debugTestHarness:
      defaultChroniclesStream.outputs[2].writer = fileFlush
    else:
      defaultChroniclesStream.outputs[2].writer = noOutput

proc run(): Future[bool] {.async: (raises: []).} =
  let startTime = now().format("yyyy-MM-dd'_'HH:mm:ss")
  let logsDir =
    currentSourcePath.parentDir() / "integration" / "logs" /
    sanitize(startTime & "__IntegrationTests")
  try:
    if DebugTestHarness or DebugHardhat or DebugCodexNodes:
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

  setupLogging(TestManager.logFile(logsDir), DebugTestHarness)

  let manager = TestManager.new(
    configs = TestConfigs,
    logsDir,
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
