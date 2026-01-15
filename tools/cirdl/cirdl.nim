import std/os
import std/streams
import pkg/chronicles
import pkg/chronos
import pkg/ethers
import pkg/questionable
import pkg/questionable/results
import pkg/zippy/tarballs
import pkg/chronos/apps/http/httpclient
import ../../codex/contracts/marketplace
import ../../codex/contracts/deployment

proc consoleLog(logLevel: LogLevel, msg: LogOutputStr) {.gcsafe.} =
  try:
    stdout.write(msg)
    stdout.flushFile()
  except IOError as err:
    logLoggingFailure(cstring(msg), err)

proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
  discard

defaultChroniclesStream.outputs[0].writer = consoleLog
defaultChroniclesStream.outputs[1].writer = noOutput
defaultChroniclesStream.outputs[2].writer = noOutput

proc printHelp() =
  info "Usage: ./cirdl [circuitPath] [rpcEndpoint] ([marketplaceAddress])"
  info "  circuitPath: path where circuit files will be placed."
  info "  rpcEndpoint: URL of web3 RPC endpoint."
  info "  marketplaceAddress: Address of deployed Storage marketplace contracts. If left out, will auto-discover based on connected network."

proc getMarketplaceAddress(
    provider: JsonRpcProvider, mpAddressOverride: ?Address
): Future[?Address] {.async.} =
  let deployment = Deployment.new(provider, mpAddressOverride)
  let address = await deployment.address(Marketplace)

  return address

proc getCircuitHash(
    provider: JsonRpcProvider, marketplaceAddress: Address
): Future[?!string] {.async.} =
  let marketplace = Marketplace.new(marketplaceAddress, provider)
  let config = await marketplace.configuration()
  return success config.proofs.zkeyHash

proc formatUrl(hash: string): string =
  "https://circuit.codex.storage/proving-key/" & hash

proc retrieveUrl(uri: string): Future[seq[byte]] {.async.} =
  let httpSession = HttpSessionRef.new()
  try:
    let resp = await httpSession.fetch(parseUri(uri))
    return resp.data
  finally:
    await noCancel(httpSession.closeWait())

proc downloadZipfile(url: string, filepath: string): Future[?!void] {.async.} =
  try:
    let file = await retrieveUrl(url)
    var s = newFileStream(filepath, fmWrite)
    for b in file:
      s.write(b)
    s.close()
  except Exception as exc:
    return failure(exc.msg)
  success()

proc unzip(zipfile: string, targetPath: string): ?!void =
  try:
    extractAll(zipfile, targetPath)
  except Exception as exc:
    return failure(exc.msg)
  success()

proc copyFiles(unpackDir: string, circuitPath: string): ?!void =
  try:
    for file in walkDir(unpackDir):
      copyFileToDir(file.path, circuitPath)
  except Exception as exc:
    return failure(exc.msg)
  success()

proc main() {.async.} =
  info "Storage Circuit Downloader, Aww yeah!"
  let args = os.commandLineParams()
  if args.len < 2 or args.len > 3:
    printHelp()
    return

  let
    circuitPath = args[0]
    rpcEndpoint = args[1]
    zipfile = "circuit.tar.gz"
    unpackFolder = "." / "tempunpackfolder"

  var mpAddressOverride: ?Address

  if args.len == 3:
    without parsed =? Address.init(args[2]):
      raise newException(ValueError, "Invalid ethereum address")
    mpAddressOverride = some parsed

  debug "Starting", circuitPath, rpcEndpoint

  if (dirExists(unpackFolder)):
    removeDir(unpackFolder)

  let provider = JsonRpcProvider.new(rpcEndpoint)

  without marketplaceAddress =?
    (await getMarketplaceAddress(provider, mpAddressOverride)), err:
    error "No known marketplace address, nor any specified manually", msg = err.msg
    return

  info "Marketplace address", address = $marketplaceAddress

  without circuitHash =? (await getCircuitHash(provider, marketplaceAddress)), err:
    error "Failed to get circuit hash", msg = err.msg
    return
  debug "Got circuithash", circuitHash

  let url = formatUrl(circuitHash)
  info "Download URL", url
  if dlErr =? (await downloadZipfile(url, zipfile)).errorOption:
    error "Failed to download circuit file", msg = dlErr.msg
    return
  debug "Download completed"

  if err =? unzip(zipfile, unpackFolder).errorOption:
    error "Failed to unzip file", msg = err.msg
    return
  debug "Unzip completed"

  # Unpack library cannot unpack into existing directory. We also cannot
  # delete the targer directory and have the library recreate it because
  # Logos Storage has likely created it and set correct permissions.
  # So, we unpack to a temp folder and move the files.
  if err =? copyFiles(unpackFolder, circuitPath).errorOption:
    error "Failed to copy files", msg = err.msg
    return
  debug "Files copied"

  removeFile(zipfile)
  removeDir(unpackFolder)

  debug "file and unpack folder removed"

when isMainModule:
  waitFor main()
  info "Done!"
