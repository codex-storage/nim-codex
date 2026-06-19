## check_spr - bootstrap-node liveness checker.
##
## Reads the bootstrap SPRs from the shared config file (network_presets.json by
## default) and probes each one. The probe depends on the transport advertised in
## the record:
##   * TCP addresses -> a libp2p connection is attempted.
##   * UDP addresses -> a discovery v5 (DHT) ping is sent.
## It prints a per-node report — a human-readable table by default, or JSON with
## `--format json` — and exits non-zero if any node is unreachable. A single
## `spr:` URI can also be passed for ad-hoc checks.
##
## IMPORTANT: run this from a host OUTSIDE the fleet VPCs (e.g. a GitHub-hosted
## runner), otherwise nodes advertising private/cloud-internal IPs will appear
## reachable and defeat the purpose.
##
## Usage:
##   check_spr [--source <file>] [--network <name>]... [--timeout <secs>]
##            [--format table|json] [--out <file>]
##   check_spr <spr-uri> [--timeout <secs>]
##   check_spr --help
##
## Run `check_spr --help` for a full description of every option.

import std/[json, options, os, sequtils, strutils, typetraits, strformat, terminal]

import pkg/chronicles
import pkg/chronos
import pkg/libp2p
import pkg/libp2p/crypto/rng
import pkg/codexdht/discv5/spr
import pkg/codexdht/discv5/node
import pkg/codexdht/discv5/protocol as discv5

import ../storage/presets

const
  DefaultTimeoutSecs = 10
  DefaultSource = "network_presets.json"

type OutputFormat = enum
  ## String values double as the accepted `--format` argument spellings, so the
  ## parser can compare against them directly.
  ofTable = "table"
  ofJson = "json"

type Verdict = object
  alive: bool
  reason: string

type Row = object
  network: string
  peerId: string
  address: string
  alive: bool
  reason: string

proc hasCodec(addrs: seq[MultiAddress], codec: MultiCodec): bool =
  addrs.anyIt(it.contains(codec).get(false))

proc setupLogging() =
  ## The project's `config.nims` forces `dynamic` chronicles sinks, whose output
  ## writers must be configured at runtime. Without this, every log message is
  ## dropped with a noisy "dynamic log output writer not configured" warning.
  ## Route libp2p logs to stderr so the tool's stdout (the report — a table or
  ## JSON, or the single-SPR ALIVE/DEAD verdict) stays clean and parseable.
  when defaultChroniclesStream.outputs.type.arity == 3:
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    proc stderrFlush(logLevel: LogLevel, msg: LogOutputStr) =
      try:
        stderr.write(msg)
        stderr.flushFile()
      except IOError:
        discard

    defaultChroniclesStream.outputs[0].writer = stderrFlush
    defaultChroniclesStream.outputs[1].writer = noOutput
    defaultChroniclesStream.outputs[2].writer = noOutput

proc buildSwitch(): Switch =
  SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    .withTcpTransport()
    .withNoise()
    .withYamux()
  # match storage node switch builder, for TCP
    .withMplex()
    .build()

proc checkLibp2p(
    peerId: PeerId, addresses: seq[MultiAddress], timeout: Duration
): Future[Verdict] {.async.} =
  let switch = buildSwitch()
  await switch.start()
  defer:
    await switch.stop()

  try:
    await switch.connect(peerId, addresses).wait(timeout)
    return Verdict(alive: true, reason: "libp2p connection established")
  except AsyncTimeoutError:
    return Verdict(alive: false, reason: "libp2p connection timed out")
  except CatchableError as exc:
    return Verdict(alive: false, reason: "libp2p connection failed: " & exc.msg)

proc checkDiscv5(
    record: SignedPeerRecord, timeout: Duration
): Future[Verdict] {.async.} =
  let nodeRes = newNode(record)
  if nodeRes.isErr:
    return Verdict(alive: false, reason: "cannot build discv5 node: " & $nodeRes.error)
  let targetNode = nodeRes.get()

  let rng = newRng()
  let privKey = PrivateKey.random(rng).tryGet()
  let proto = discv5.newProtocol(
    privKey, none(IpAddress), none(Port), none(Port), bindPort = Port(0), rng = rng
  )

  try:
    proto.open()
  except CatchableError as exc:
    return Verdict(alive: false, reason: "failed to open discv5: " & exc.msg)
  defer:
    await proto.closeWait()

  try:
    let pong = await discv5.ping(proto, targetNode).wait(timeout)
    if pong.isOk:
      return Verdict(alive: true, reason: "discv5 pong received")
    else:
      return Verdict(alive: false, reason: "discv5 ping failed: " & $pong.error)
  except AsyncTimeoutError:
    return Verdict(alive: false, reason: "discv5 ping timed out")
  except CatchableError as exc:
    return Verdict(alive: false, reason: "discv5 ping failed: " & exc.msg)

proc probe(record: SignedPeerRecord, timeout: Duration): Future[Verdict] {.async.} =
  let addresses = record.data.addresses.mapIt(it.address)
  if addresses.len == 0:
    return Verdict(alive: false, reason: "SPR contains no addresses")

  if hasCodec(addresses, multiCodec("tcp")):
    return await checkLibp2p(record.data.peerId, addresses, timeout)
  elif hasCodec(addresses, multiCodec("udp")):
    return await checkDiscv5(record, timeout)
  else:
    return Verdict(alive: false, reason: "no tcp or udp addresses to probe")

proc probeRecords(
    source, networkFilter: string, timeout: Duration
): Future[seq[Row]] {.async.} =
  let presets = loadNetworkPresets(source)
  for preset in presets:
    if networkFilter.len > 0 and preset.name != networkFilter:
      continue
    for rec in preset.rawRecords:
      let parsed = SignedPeerRecord.parse(rec)
      if parsed.isErr:
        result.add Row(
          network: preset.name,
          alive: false,
          reason: "SPR parse failed: " & parsed.error,
        )
        continue
      let record = parsed.get
      let v = await probe(record, timeout)
      result.add Row(
        network: preset.name,
        peerId: $record.data.peerId,
        address: record.data.addresses.mapIt($it.address).deduplicate.join(", "),
        alive: v.alive,
        reason: v.reason,
      )

const
  TableHeader = "FLEET        RESULT  ADDRESS                                    REASON"
  TableRule = '-'.repeat(TableHeader.len)

proc formatRow(r: Row): string =
  ## One table line for a probed node. The status cell is fixed-width ("DEAD " is
  ## padded to match "ALIVE") so columns line up regardless of the verdict. ANSI
  ## color, when added by the styled renderer, is zero-width on screen, so the
  ## plain-text alignment computed here stays visually correct.
  let status = if r.alive: "ALIVE" else: "DEAD "
  r.network.alignLeft(12) & " " & status & "  " & r.address.alignLeft(43) & " " &
    r.reason

proc renderTable(rows: seq[Row]): string =
  ## Plain (uncolored) table — used for files and non-interactive stdout, where
  ## ANSI escapes would be corruption rather than decoration.
  result = TableHeader & "\n" & TableRule
  for r in rows:
    result.add("\n" & formatRow(r))

proc printStyledTable(rows: seq[Row]) =
  ## Colored table for an interactive terminal: alive rows green, dead rows red.
  ## styledEcho writes ANSI escapes unconditionally, so callers must restrict this
  ## to a TTY (see isatty guard at the call site).
  styledEcho(styleBright, TableHeader)
  styledEcho(styleDim, TableRule)
  for r in rows:
    styledEcho(if r.alive: fgGreen else: fgRed, formatRow(r))

proc rowsToJson(rows: seq[Row]): JsonNode =
  result = newJArray()
  for r in rows:
    result.add %*{
      "network": r.network,
      "peerId": r.peerId,
      "address": r.address,
      "alive": r.alive,
      "reason": r.reason,
    }

proc parseTimeout(s: string): int =
  try:
    parseInt(s)
  except ValueError:
    quit("Error: timeout must be an integer number of seconds", QuitFailure)

proc parseFormat(s: string): OutputFormat =
  case s
  of $ofTable:
    ofTable
  of $ofJson:
    ofJson
  else:
    quit("Error: format must be '" & $ofTable & "' or '" & $ofJson & "'", QuitFailure)

proc printHelp() =
  echo """check_spr - bootstrap-node liveness checker.

Reads bootstrap SPRs from a config file and probes each one (libp2p connect for
TCP addresses, discv5 ping for UDP). Prints a per-node report (a table by
default, JSON with --format json) and exits non-zero if any node is unreachable.
A single spr: URI can be passed for an ad-hoc check.

IMPORTANT: run from a host OUTSIDE the fleet VPCs (e.g. a GitHub-hosted runner),
otherwise nodes advertising private/cloud-internal IPs appear reachable and
defeat the purpose.

Usage:
  check_spr [options]
  check_spr <spr-uri> [--timeout <secs>]

Options:
  --source <file>    Config file to read SPRs from (default: """ &
    DefaultSource & """).
  --network <name>   Only probe the preset with this network name.
  --timeout <secs>   Per-node probe timeout in seconds (default: """ &
    $DefaultTimeoutSecs & """).
  --format <fmt>     Output format: "table" (default) or "json". "table" is the
                     human-readable table; "json" is a pretty-printed summary.
  --out <file>       Write the output to <file> instead of stdout. The content
                     is whichever --format is selected (table or json).
  --help, -h         Show this help and exit.

Arguments:
  <spr-uri>          A single "spr:" URI to probe instead of reading the config
                     file. Prints ALIVE/DEAD and exits with the matching status;
                     this mode ignores --format and --out."""

when isMainModule:
  setupLogging()

  var
    source = DefaultSource
    networkFilter = ""
    timeoutSecs = DefaultTimeoutSecs
    singleSpr = ""
    format = ofTable
    outFile = ""

  let params = commandLineParams()
  var i = 0
  while i < params.len:
    case params[i]
    of "--help", "-h":
      printHelp()
      quit(QuitSuccess)
    of "--source":
      inc i
      source = params[i]
    of "--network":
      inc i
      networkFilter = params[i]
    of "--timeout":
      inc i
      timeoutSecs = parseTimeout(params[i])
    of "--format":
      inc i
      format = parseFormat(params[i])
    of "--out":
      inc i
      outFile = params[i]
    else:
      if params[i].startsWith("spr:"):
        singleSpr = params[i]
      else:
        quit("Error: unknown argument: " & params[i], QuitFailure)
    inc i

  let timeout = timeoutSecs.seconds

  if singleSpr.len > 0:
    let parsed = SignedPeerRecord.parse(singleSpr)
    if parsed.isErr:
      quit("Error: " & parsed.error, QuitFailure)
    let v = waitFor probe(parsed.get, timeout)
    echo (if v.alive: "ALIVE: " else: "DEAD: "), v.reason
    quit(if v.alive: QuitSuccess else: QuitFailure)

  let rows = waitFor probeRecords(source, networkFilter, timeout)

  if outFile.len > 0:
    # Files (and the JSON form) must stay plain — ANSI color codes would corrupt
    # them — so always write the uncolored rendering. writeFile does not append a
    # trailing newline the way echo does, so add one to keep the file POSIX-clean.
    let output =
      case format
      of ofTable:
        renderTable(rows)
      of ofJson:
        pretty(rowsToJson(rows))
    writeFile(outFile, output & "\n")
    # The report is in the file, not on stdout, so point the caller at it. Use
    # the absolute path so the line is unambiguous regardless of the cwd.
    #!fmt: off
    styledEcho bgWhite, fgBlack, styleBright,
      "\n\n  ",
      styleUnderscore,
      "ℹ️  BOOTSTRAP HEALTH REPORT ℹ️\n\n",
      resetStyle, bgWhite, fgBlack, styleBright,
      """  Bootstrap health report for this run will be available at:""",
      resetStyle, bgWhite, fgBlack,
      &"\n\n  {absolutePath(outFile)}\n\n",
      resetStyle, bgWhite, fgBlack, styleBright,
      "  NOTE: For CI runs, the report will be displayed in the workflow summary\n"
      #!fmt: on
  else:
    case format
    of ofTable:
      # Color only when stdout is an interactive terminal; when piped or
      # redirected, fall back to the plain table so escapes never reach the
      # consumer (std/terminal emits ANSI unconditionally on POSIX).
      if isatty(stdout):
        printStyledTable(rows)
      else:
        echo renderTable(rows)
    of ofJson:
      echo pretty(rowsToJson(rows))

  let dead = rows.filterIt(not it.alive)
  
  if outFile.len > 0:
    if dead.len > 0:
      styledEcho styleBright,
        fgRed,
        &"\n\n[❌ ERROR] ",
        resetStyle,
        "One or more bootstrap nodes are unreachable, see report for details.\n\n"
    else:
      styledEcho styleBright,
        fgGreen,
        &"\n\n[✅ SUCCESS] ",
        resetStyle,
        "All bootstrap nodes are reachable, see report for details.\n\n"

  if dead.len > 0:
    quit(QuitFailure)
