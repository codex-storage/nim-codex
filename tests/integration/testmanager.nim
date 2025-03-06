import std/os
import std/strformat
import std/terminal
from std/times import fromUnix, format, now
from std/unicode import toUpper
import std/unittest
import pkg/chronos
import pkg/chronos/asyncproc
import pkg/codex/conf
import pkg/codex/logutils
import pkg/codex/utils/trackedfutures
import pkg/questionable
import pkg/questionable/results
import ./hardhatprocess
import ./utils
import ../examples

type
  Hardhat = ref object
    process: HardhatProcess
    output: seq[string]
    port: int

  TestManagerConfig* = object # Echoes stdout from Hardhat process
    debugHardhat*: bool
    # Echoes stdout from the integration test file process. Codex process logs
    # can also be output if a test uses a multinodesuite, requires
    # CodexConfig.debug to be enabled
    debugCodexNodes*: bool
    # Shows test status updates at regular time intervals. Useful for running
    # locally while attended. Set to false for unattended runs, eg CI.
    showContinuousStatusUpdates*: bool
    logsDir*: string
    testTimeout*: Duration # individual test timeout

  TestManager* = ref object
    config: TestManagerConfig
    testConfigs: seq[IntegrationTestConfig]
    tests: seq[IntegrationTest]
    hardhats: seq[Hardhat]
    lastHardhatPort: int
    lastCodexApiPort: int
    lastCodexDiscPort: int
    timeStart: ?Moment
    timeEnd: ?Moment
    codexPortLock: AsyncLock
    hardhatPortLock: AsyncLock
    hardhatProcessLock: AsyncLock
    trackedFutures: TrackedFutures

  IntegrationTestConfig* = object
    startHardhat: bool
    testFile: string
    name: string

  IntegrationTestStatus = enum ## The status of a test when it is done.
    New # Test not yet run
    Running # Test currently running
    Ok # Test file launched, and exited with 0. Indicates all tests completed and passed.
    Failed
      # Test file launched, but exited with a non-zero exit code. Indicates either the test file did not compile, or one or more of the tests in the file failed
    Timeout # Test file launched, but the tests did not complete before the timeout.
    Error
      # Test file did not launch correctly. Indicates an error occurred running the tests (usually an error in the harness).

  IntegrationTest = ref object
    manager: TestManager
    config: IntegrationTestConfig
    process: AsyncProcessRef
    timeStart: ?Moment
    timeEnd: ?Moment
    output: ?!TestOutput
    testId: string # when used in datadir path, prevents data dir clashes
    status: IntegrationTestStatus
    command: string
    logsDir: string

  TestOutput = ref object
    stdOut*: string
    stdErr*: string
    exitCode*: ?int

  TestManagerError* = object of CatchableError

  Border {.pure.} = enum
    Left
    Right

  Align {.pure.} = enum
    Left
    Right

  MarkerPosition {.pure.} = enum
    Start
    Finish

{.push raises: [].}

logScope:
  topics = "testing integration testmanager"

proc printOutputMarker(
  test: IntegrationTest, position: MarkerPosition, msg: string
) {.gcsafe, raises: [].}

proc raiseTestManagerError(
    msg: string, parent: ref CatchableError = nil
) {.raises: [TestManagerError].} =
  raise newException(TestManagerError, msg, parent)

template echoStyled(args: varargs[untyped]) =
  try:
    styledEcho args
  except CatchableError as parent:
    # no need to re-raise this, as it'll eventually have to be logged only
    error "failed to print to terminal", error = parent.msg

template ignoreCancelled(body) =
  try:
    body
  except CancelledError:
    discard

func logFile*(_: type TestManager, dir: string): string =
  dir / "testmanager.chronicles.log"

func logFile(manager: TestManager): string =
  TestManager.logFile(manager.config.logsDir)

func logFile(test: IntegrationTest, fileName: string): string =
  let testName = sanitize(test.config.name)
  test.logsDir / &"{testName}.{fileName}"

func isErrorLike(output: ?!TestOutput): bool =
  # Three lines is an arbitrary number, however it takes into account the
  # "LevelDB already build" line and blank line that is output to stdout. This
  # typically means that the exitCode == 1 (test failed) and if stdout is short,
  # we're dealing with an error
  o =? output and o.stdOut.countLines() < 3

proc new*(
    _: type TestManager,
    config: TestManagerConfig,
    testConfigs: seq[IntegrationTestConfig],
): TestManager =
  TestManager(
    config: config,
    testConfigs: testConfigs,
    lastHardhatPort: 8545,
    lastCodexApiPort: 8000,
    lastCodexDiscPort: 18000, # keep separated by 10000 to minimise overlap
    trackedFutures: TrackedFutures.new(),
  )

func init*(
    _: type IntegrationTestConfig, testFile: string, startHardhat: bool, name = ""
): IntegrationTestConfig =
  IntegrationTestConfig(
    testFile: testFile,
    name: if name == "": testFile.extractFilename else: name,
    startHardhat: startHardhat,
  )

template withLock*(lock: AsyncLock, body: untyped) =
  if lock.isNil:
    lock = newAsyncLock()

  await lock.acquire()
  try:
    body
  finally:
    try:
      lock.release()
    except AsyncLockError as parent:
      raiseTestManagerError "lock error", parent

proc duration(manager: TestManager): Duration =
  let now = Moment.now()
  (manager.timeEnd |? now) - (manager.timeStart |? now)

proc allTestsPassed*(manager: TestManager): ?!bool =
  for test in manager.tests:
    if test.status in {IntegrationTestStatus.New, IntegrationTestStatus.Running}:
      return failure "Integration tests not complete"

    if test.status != IntegrationTestStatus.Ok:
      return success false

  return success true

proc duration(test: IntegrationTest): Duration =
  let now = Moment.now()
  (test.timeEnd |? now) - (test.timeStart |? now)

proc startHardhat(
    test: IntegrationTest
): Future[Hardhat] {.async: (raises: [CancelledError, TestManagerError]).} =
  var args: seq[string] = @[]
  var port: int

  let hardhat = Hardhat.new()

  proc onOutputLineCaptured(line: string) {.raises: [].} =
    hardhat.output.add line

  withLock(test.manager.hardhatPortLock):
    port = await nextFreePort(test.manager.lastHardhatPort + 1)
    test.manager.lastHardhatPort = port

  args.add("--port")
  args.add($port)
  if test.manager.config.debugHardhat:
    args.add("--log-file=" & test.logsDir / "hardhat.log")

  trace "starting hardhat process on port ", port
  try:
    withLock(test.manager.hardhatProcessLock):
      let node = await HardhatProcess.startNode(
        args, false, "hardhat for '" & test.config.name & "'", onOutputLineCaptured
      )
      hardhat.process = node
      hardhat.port = port
      await node.waitUntilStarted()
      return hardhat
  except CancelledError as e:
    raise e
  except CatchableError as e:
    if not hardhat.isNil:
      test.printOutputMarker(MarkerPosition.Start, "hardhat stdout")
      for line in hardhat.output:
        echo line
      test.printOutputMarker(MarkerPosition.Finish, "hardhat stdout")
    raiseTestManagerError "hardhat node failed to start: " & e.msg, e

proc printResult(test: IntegrationTest, colour: ForegroundColor) =
  echoStyled styleBright,
    colour,
    &"[{toUpper $test.status}] ",
    resetStyle,
    test.config.name,
    resetStyle,
    styleDim,
    &" ({test.duration})"

proc printOutputMarker(test: IntegrationTest, position: MarkerPosition, msg: string) =
  if position == MarkerPosition.Start:
    echo ""

  echoStyled styleBright,
    bgWhite, fgBlack, &"----- {toUpper $position} {test.config.name} {msg} -----"

  if position == MarkerPosition.Finish:
    echo ""

proc colorise(output: string): string =
  proc setColour(text: string, colour: ForegroundColor): string =
    &"{ansiForegroundColorCode(colour, true)}{text}{ansiResetCode}"

  let replacements = @[("[OK]", fgGreen), ("[FAILED]", fgRed), ("[Suite]", fgBlue)]
  result = output
  for (text, colour) in replacements:
    result = result.replace(text, text.setColour(colour))

proc printResult(test: IntegrationTest, printStdOut, printStdErr: bool) =
  case test.status
  of IntegrationTestStatus.New:
    test.printResult(fgBlue)
  of IntegrationTestStatus.Running:
    test.printResult(fgCyan)
  of IntegrationTestStatus.Error:
    if error =? test.output.errorOption:
      test.printResult(fgRed)
      test.printOutputMarker(MarkerPosition.Start, "test harness errors")
      echo "Error during test execution: ", error.msg
      echo "Stacktrace: ", error.getStackTrace()
      test.printOutputMarker(MarkerPosition.Finish, "test harness errors")
    if output =? test.output:
      if printStdErr:
        test.printOutputMarker(MarkerPosition.Start, "test file errors (stderr)")
        echo output.stdErr
        test.printOutputMarker(MarkerPosition.Finish, "test file errors (stderr)")
  of IntegrationTestStatus.Failed:
    if output =? test.output:
      if printStdErr or test.output.isErrorLike:
        test.printOutputMarker(MarkerPosition.Start, "test file errors (stderr)")
        echo output.stdErr
        test.printOutputMarker(MarkerPosition.Finish, "test file errors (stderr)")
      if printStdOut:
        test.printOutputMarker(MarkerPosition.Start, "codex node output (stdout)")
        echo output.stdOut.colorise
        test.printOutputMarker(MarkerPosition.Finish, "codex node output (stdout)")
    test.printResult(fgRed)
  of IntegrationTestStatus.Timeout:
    if printStdOut and output =? test.output:
      test.printOutputMarker(MarkerPosition.Start, "codex node output (stdout)")
      echo output.stdOut.colorise
      test.printOutputMarker(MarkerPosition.Finish, "codex node output (stdout)")
    test.printResult(fgYellow)
  of IntegrationTestStatus.Ok:
    if printStdOut and output =? test.output:
      test.printOutputMarker(MarkerPosition.Start, "codex node output (stdout)")
      echo output.stdOut.colorise
      test.printOutputMarker(MarkerPosition.Finish, "codex node output (stdout)")
    test.printResult(fgGreen)

proc printSummary(test: IntegrationTest) =
  test.printResult(printStdOut = false, printStdErr = false)

proc printStart(test: IntegrationTest) =
  echoStyled styleBright,
    fgMagenta, &"[Integration test started] ", resetStyle, test.config.name

proc buildCommand(
    test: IntegrationTest, hardhatPort: ?int
): Future[string] {.async: (raises: [CancelledError, TestManagerError]).} =
  var hhPort = string.none
  if test.config.startHardhat:
    without port =? hardhatPort:
      raiseTestManagerError "hardhatPort required when 'config.startHardhat' is true"
    hhPort = some "-d:HardhatPort=" & $port

  var testFile: string
  try:
    testFile = absolutePath(
      test.config.testFile, root = currentSourcePath().parentDir().parentDir()
    )
  except ValueError as parent:
    raiseTestManagerError "bad file name, testFile: " & test.config.testFile, parent

  withLock(test.manager.codexPortLock):
    # Increase the port by 1000 to allow each test to run 1000 codex nodes
    # (clients, SPs, validators) giving a good chance the port will be free. We
    # cannot rely on `nextFreePort` in multinodes entirely as there could be a
    # concurrency issue where the port is determined free in mulitiple tests and
    # then there is a clash during the run. Windows, in particular, does not
    # like giving up ports.
    let apiPort = await nextFreePort(test.manager.lastCodexApiPort + 1000)
    test.manager.lastCodexApiPort = apiPort
    let discPort = await nextFreePort(test.manager.lastCodexDiscPort + 1000)
    test.manager.lastCodexDiscPort = discPort

    withLock(test.manager.hardhatPortLock):
      try:
        return
          #!fmt: off
          "nim c " &
            &"-d:CodexApiPort={apiPort} " &
            &"-d:CodexDiscPort={discPort} " &
            &"-d:DebugCodexNodes={test.manager.config.debugCodexNodes} " &
            &"-d:DebugHardhat={test.manager.config.debugHardhat} " &
            &"-d:LogsDir={test.logsDir} " &
            (hhPort |? "") & " " &
            &"-d:TestId={test.testId} " &
            # Log multinodes chronicles logs to file. If DebugCodexNodes is also
            # enabled, the chronicles output will also get logged to stdout.
            "-d:chronicles_log_level=TRACE " &
            "-d:chronicles_disabled_topics=websock,JSONRPC-HTTP-CLIENT,JSONRPC-WS-CLIENT " &
            "-d:chronicles_sinks=textlines[nocolors,file] " &
            "--verbosity:0 " &
            "--hints:off " &
            "-d:release " &
          "-r " &
            &"{testFile}"
          #!fmt: on
      except ValueError as parent:
        raiseTestManagerError "bad command --\n" & ", apiPort: " & $apiPort &
          ", discPort: " & $discPort & ", testFile: " & testFile & ", error: " &
          parent.msg, parent

proc setup(
    test: IntegrationTest
): Future[?Hardhat] {.async: (raises: [CancelledError, TestManagerError]).} =
  var hardhat = Hardhat.none
  var hardhatPort = int.none

  if test.config.startHardhat:
    let hh = await test.startHardhat()
    hardhat = some hh
    hardhatPort = some hh.port
    test.manager.hardhats.add hh

  test.command = await test.buildCommand(hardhatPort)

  return hardhat

proc teardownHardhat(test: IntegrationTest, hardhat: Hardhat) {.async: (raises: []).} =
  try:
    trace "Stopping hardhat", name = test.config.name
    await noCancel hardhat.process.stop()
    trace "Hardhat stopped", name = test.config.name
  except CatchableError as e: # CancelledError not raised due to noCancel
    warn "Failed to stop hardhat node, continuing",
      error = e.msg, test = test.config.name

  if test.manager.config.debugHardhat:
    test.printOutputMarker(MarkerPosition.Start, "Hardhat stdout")
    for line in hardhat.output:
      echo line
    test.printOutputMarker(MarkerPosition.Finish, "Hardhat stdout")

  test.manager.hardhats.keepItIf(it != hardhat)

proc teardownTest(
    test: IntegrationTest,
    stdOutStream, stdErrStream:
      Future[seq[byte]].Raising([CancelledError, AsyncStreamError]),
) {.async: (raises: []).} =
  test.timeEnd = some Moment.now()

  if not test.process.isNil:
    var output = test.output.expect("should have output value")
    if test.process.running |? false:
      try:
        output.exitCode =
          some (await noCancel test.process.terminateAndWaitForExit(500.millis))
        trace "Test process terminated", exitCode = output.exitCode
      except AsyncProcessError, AsyncProcessTimeoutError:
        warn "Test process failed to terminate, check for zombies"

    try:
      output.stdOut = string.fromBytes(await noCancel stdOutStream)
      output.stdErr = string.fromBytes(await noCancel stdErrStream)
      test.output = success output
      test.logFile("stdout.log").appendFile(output.stdOut.stripAnsi)
      if test.status == IntegrationTestStatus.Error or test.output.isErrorLike:
        test.logFile("stderr.log").appendFile(output.stdErr.stripAnsi)
    except IOError as e:
      warn "Failed to write test stdout and stderr to file", error = e.msg
    except AsyncStreamError as e:
      test.timeEnd = some Moment.now()
      error "Failed to read test process output stream", error = e.msg
      test.output = TestOutput.failure(e)
      test.status = IntegrationTestStatus.Error

    await test.process.closeWait()
    trace "Test process output streams closed"

proc teardown(
    test: IntegrationTest,
    hardhat: ?Hardhat,
    stdOutStream, stdErrStream:
      Future[seq[byte]].Raising([CancelledError, AsyncStreamError]),
) {.async: (raises: []).} =
  if test.config.startHardhat and hardhat =? hardhat and not hardhat.process.isNil:
    await test.teardownHardhat(hardhat)

  await test.teardownTest(stdOutStream, stdErrStream)

proc untilTimeout(
    fut: InternalRaisesFuture, timeout: Duration
): Future[void] {.async: (raises: [CancelledError, AsyncTimeoutError]).} =
  ## Returns a Future that completes when either fut finishes or timeout elapses,
  ## or if they finish at the same time. If timeout elapses, an AsyncTimeoutError
  ## is raised. If fut fails, its error is raised.

  let timer = sleepAsync(timeout)
  defer:
    # Called even when exception raised, including CancelledError. `race` does
    # not cancel its futures when it's cancelled, so cancel here, which is ok
    # even if they're already completed.
    await fut.cancelAndWait()
    await timer.cancelAndWait()

  try:
    discard await race(fut, timer)
  except ValueError as e:
    raiseAssert "should not happen"

  if fut.finished(): # or fut and timer both finished simultaneously
    if fut.failed():
      await fut # raise fut error
      return # unreachable, for readability
  else: # timeout
    raise newException(AsyncTimeoutError, "Timed out")

proc start(test: IntegrationTest) {.async: (raises: []).} =
  logScope:
    name = test.config.name
    duration = test.duration

  trace "Running test"

  # if test.manager.config.debugCodexNodes:
  test.logsDir = test.manager.config.logsDir / sanitize(test.config.name)
  try:
    createDir(test.logsDir)
  except CatchableError as e:
    test.timeStart = some Moment.now()
    test.timeEnd = some Moment.now()
    test.status = IntegrationTestStatus.Error
    test.output = TestOutput.failure(e)
    error "failed to create test log dir", logDir = test.logsDir, error = e.msg
    return

  test.timeStart = some Moment.now()
  test.status = IntegrationTestStatus.Running

  var hardhat = none Hardhat

  ignoreCancelled:
    try:
      hardhat = await test.setup()
    except TestManagerError as e:
      test.timeEnd = some Moment.now()
      test.status = IntegrationTestStatus.Error
      test.output = TestOutput.failure(e)
      error "Failed to start hardhat and build command", error = e.msg
      return

    trace "Starting parallel integration test",
      command = test.command, timeout = test.manager.config.testTimeout
    test.printStart()
    try:
      test.process = await startProcess(
        command = test.command,
        # arguments = test.command.split(" "),
        options = {AsyncProcessOption.EvalCommand},
        stdoutHandle = AsyncProcess.Pipe,
        stderrHandle = AsyncProcess.Pipe,
      )
    except AsyncProcessError as e:
      test.timeEnd = some Moment.now()
      error "Failed to start test process", error = e.msg
      test.output = TestOutput.failure(e)
      test.status = IntegrationTestStatus.Error
      return

    var output = TestOutput.new()
    test.output = success(output)
    let outputReader = test.process.stdoutStream.read()
    let errorReader = test.process.stderrStream.read()

    defer:
      # called at the end of successful runs but also when `start` is cancelled
      # (from `untilTimeout`) due to a timeout. This defer runs first before
      # `untilTimeout` exceptions are handled in `run`
      await test.teardown(hardhat, outputReader, errorReader)
        # doesn't raise CancelledError, so noCancel not needed

    output.exitCode =
      try:
        some (await test.process.waitForExit(test.manager.config.testTimeout))
      except AsyncProcessTimeoutError as e:
        test.timeEnd = some Moment.now()
        test.status = IntegrationTestStatus.Timeout
        error "Test process failed to exit before timeout",
          timeout = test.manager.config.testTimeout
        return
      except AsyncProcessError as e:
        test.timeEnd = some Moment.now()
        test.status = IntegrationTestStatus.Error
        test.output = TestOutput.failure(e)
        error "Test failed to complete", error = e.msg
        return

    test.status =
      if output.exitCode == some QuitSuccess:
        IntegrationTestStatus.Ok
      elif output.exitCode == some QuitFailure:
        IntegrationTestStatus.Failed
      else:
        IntegrationTestStatus.Error

proc continuallyShowUpdates(manager: TestManager) {.async: (raises: []).} =
  ignoreCancelled:
    while true:
      let sleepDuration = if manager.duration < 5.minutes: 30.seconds else: 1.minutes

      if manager.tests.len > 0:
        echo ""
        echoStyled styleBright,
          bgWhite, fgBlack, &"Integration tests status after {manager.duration}"

      for test in manager.tests:
        test.printSummary()

      if manager.tests.len > 0:
        echo ""

      await sleepAsync(sleepDuration)

proc run(test: IntegrationTest) {.async: (raises: []).} =
  ignoreCancelled:
    let futStart = test.start()
    # await futStart

    try:
      await futStart.untilTimeout(test.manager.config.testTimeout)
    except AsyncTimeoutError:
      error "Test timed out"
      test.timeEnd = some Moment.now()
      test.status = IntegrationTestStatus.Timeout
      # futStart will be cancelled by untilTimeout and that will run the
      # teardown procedure (in defer)

    test.printResult(
      printStdOut = test.status != IntegrationTestStatus.Ok,
      printStdErr = test.status == IntegrationTestStatus.Error,
    )
    logScope:
      name = test.config.name
      duration = test.duration

    case test.status
    of IntegrationTestStatus.New:
      raiseAssert "Test has completed, but is in the New state"
    of IntegrationTestStatus.Running:
      raiseAssert "Test has completed, but is in the Running state"
    of IntegrationTestStatus.Error:
      error "Test errored",
        exitCode = test.output.option .? exitCode,
        error = test.output.errorOption .? msg,
        stack = test.output.errorOption .? getStackTrace()
    of IntegrationTestStatus.Failed:
      error "Test failed", exitCode = test.output.option .? exitCode
    of IntegrationTestStatus.Timeout:
      error "Test timed out"
    of IntegrationTestStatus.Ok:
      notice "Test passed"

proc runTests(manager: TestManager) {.async: (raises: [CancelledError]).} =
  var testFutures: seq[Future[void]]

  manager.timeStart = some Moment.now()

  echoStyled styleBright,
    bgWhite, fgBlack, "\n[Integration Test Manager] Starting parallel integration tests"
  notice "[Integration Test Manager] Starting parallel integration tests",
    config = manager.config

  for config in manager.testConfigs:
    var test =
      IntegrationTest(manager: manager, config: config, testId: $uint16.example)
    manager.tests.add test

    let futRun = test.run()
    testFutures.add futRun

  defer:
    for fut in testFutures:
      await fut.cancelAndWait()

  await allFutures testFutures

  manager.timeEnd = some Moment.now()

proc withBorder(
    msg: string, align = Align.Left, width = 67, borders = {Border.Left, Border.Right}
): string =
  if borders.contains(Border.Left):
    result &= "| "
  if align == Align.Left:
    result &= msg.alignLeft(width)
  elif align == Align.Right:
    result &= msg.align(width)
  if borders.contains(Border.Right):
    result &= " |"

proc printResult(manager: TestManager) {.raises: [TestManagerError].} =
  var successes = 0
  var totalDurationSerial: Duration
  echo ""
  echoStyled styleBright, styleUnderscore, bgWhite, fgBlack, &"INTEGRATION TESTS RESULT"

  for test in manager.tests:
    totalDurationSerial += test.duration
    if test.status == IntegrationTestStatus.Ok:
      inc successes
    # because debug output can really make things hard to read, show a nice
    # summary of test results
    test.printSummary()

  # estimated time saved as serial execution with a single hardhat instance
  # incurs less overhead
  let relativeTimeSaved =
    ((totalDurationSerial - manager.duration).nanos * 100) div
    (totalDurationSerial.nanos)
  let passingStyle = if successes < manager.tests.len: fgRed else: fgGreen

  echo "\n▢=====================================================================▢"
  echoStyled "| ",
    styleBright,
    styleUnderscore,
    "INTEGRATION TEST SUMMARY",
    resetStyle,
    "".withBorder(Align.Right, 43, {Border.Right})
  echo "".withBorder()
  echoStyled styleBright,
    "| TOTAL TIME      : ",
    resetStyle,
    ($manager.duration).withBorder(Align.Right, 49, {Border.Right})
  echoStyled styleBright,
    "| TIME SAVED (EST): ",
    resetStyle,
    (&"{relativeTimeSaved}%").withBorder(Align.Right, 49, {Border.Right})
  echoStyled "| ",
    styleBright,
    passingStyle,
    "PASSING         : ",
    resetStyle,
    passingStyle,
    (&"{successes} / {manager.tests.len}").align(49),
    resetStyle,
    " |"
  echo "▢=====================================================================▢"
  notice "INTEGRATION TEST SUMMARY",
    totalTime = manager.duration,
    timeSavedEst = &"{relativeTimeSaved}%",
    passing = &"{successes} / {manager.tests.len}"

proc start*(
    manager: TestManager
) {.async: (raises: [CancelledError, TestManagerError]).} =
  if manager.config.showContinuousStatusUpdates:
    let fut = manager.continuallyShowUpdates()
    manager.trackedFutures.track fut
    asyncSpawn fut

  let futRunTests = manager.runTests()
  manager.trackedFutures.track futRunTests

  await futRunTests

  manager.printResult()

proc stop*(manager: TestManager) {.async: (raises: []).} =
  await manager.trackedFutures.cancelTracked()

  for test in manager.tests:
    if not test.process.isNil:
      try:
        if test.process.running |? false:
          discard await noCancel test.process.terminateAndWaitForExit(100.millis)
          trace "Terminated running test process", name = test.config.name
      except AsyncProcessError, AsyncProcessTimeoutError:
        warn "Test process failed to terminate, ignoring...", name = test.config.name
      finally:
        trace "Closing test process' streams", name = test.config.name
        await noCancel test.process.closeWait()

  for hardhat in manager.hardhats:
    try:
      if not hardhat.process.isNil:
        await noCancel hardhat.process.stop()
        trace "Terminated running hardhat process"
    except CatchableError as e:
      trace "failed to stop hardhat node", error = e.msg
