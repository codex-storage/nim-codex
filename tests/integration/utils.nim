import std/os
import pkg/chronos
import pkg/codex/logutils

{.push raises: [].}

proc nextFreePort*(startPort: int): Future[int] {.async: (raises: [CancelledError]).} =
  proc client(server: StreamServer, transp: StreamTransport) {.async: (raises: []).} =
    await transp.closeWait()

  var port = startPort
  while true:
    trace "checking if port is free", port
    try:
      let host = initTAddress("127.0.0.1", port)
      # We use ReuseAddr here only to be able to reuse the same IP/Port when
      # there's a TIME_WAIT socket. It's useful when running the test multiple
      # times or if a test ran previously using the same port.
      var server = createStreamServer(host, client, {ReuseAddr})
      trace "port is free", port
      await server.closeWait()
      return port
    except TransportOsError:
      trace "port is not free", port
      inc port
    except TransportAddressError:
      raiseAssert "bad address"

proc sanitize*(pathSegment: string): string =
  var sanitized = pathSegment
  for invalid in invalidFilenameChars.items:
    sanitized = sanitized.replace(invalid, '_').replace(' ', '_')
  sanitized

proc getLogFile*(
    logDir, startTime, suiteName, testName, role: string, index = int.none
): string {.raises: [IOError, OSError].} =
  let logsDir =
    if logDir == "":
      currentSourcePath.parentDir() / "logs" / sanitize(startTime & "__" & suiteName) /
        sanitize(testName)
    else:
      logDir / sanitize(suiteName) / sanitize(testName)

  createDir(logsDir)

  var fn = $role
  if idx =? index:
    fn &= "_" & $idx
  fn &= ".log"

  let fileName = logsDir / fn
  return fileName
