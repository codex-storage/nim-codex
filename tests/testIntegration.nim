# import ./integration/testcli
# import ./integration/testrestapi
# import ./integration/testrestapivalidation
# import ./integration/testupdownload
# import ./integration/testsales
# import ./integration/testpurchasing
# import ./integration/testblockexpiration
# import ./integration/testmarketplace
# import ./integration/testproofs
# import ./integration/testvalidator
# import ./integration/testecbug

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
const DebugCodexNodes {.booldefine.} = true
# Shows test status updates at time intervals. Useful for running locally with
# active terminal interaction. Set to false for unattended runs, eg CI.
const ShowContinuousStatusUpdates {.booldefine.} = false
# Timeout duration (in mimutes) for EACH integration test file.
const TestTimeout {.intdefine.} = 60

proc run() {.async.} =
  when DebugTestHarness and enabledLogLevel != LogLevel.TRACE:
    styledEcho bgWhite,
      fgBlack, styleBright, "\n\n  ", styleUnderscore,
      "ADDITIONAL LOGGING AVAILABILE\n\n", resetStyle, bgWhite, fgBlack, styleBright,
      """
  More integration test harness logs available by running with
  -d:chronicles_log_level=TRACE, eg:""",
      resetStyle, bgWhite, fgBlack,
      "\n\n  nim c -d:chronicles_log_level=TRACE -r ./testIntegration.nim\n\n"

  when DebugCodexNodes:
    styledEcho bgWhite,
      fgBlack, styleBright, "\n\n  ", styleUnderscore, "ENABLE CODEX LOGGING\n\n",
      resetStyle, bgWhite, fgBlack, styleBright,
      """
  For integration test suites that are multinodesuites, or for
  tests launching a CodexProcess, ensure that CodexConfig.debug
  is enabled to see chronicles logs.
  """

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
  finally:
    trace "stopping test manager"
    await manager.stop()

waitFor run()
