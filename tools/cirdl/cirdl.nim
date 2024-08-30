import std/os
import std/streams
import pkg/chronicles
import pkg/chronos
import pkg/ethers
import pkg/questionable
import pkg/questionable/results
import pkg/zip/zipfiles
import pkg/chronos/apps/http/httpclient
import ../../codex/contracts/marketplace

## TODO: chronicles is still "Log message not delivered: [Chronicles] A writer was not configured for a dynamic log output device"
## And I am mildly annoyed by this.
defaultChroniclesStream.outputs[0].writer =
  proc (logLevel: LogLevel, msg: LogOutputStr) {.gcsafe.} =
    echo msg

proc printHelp() =
  info "Usage: ./cirdl [circuitPath] [rpcEndpoint] [marketplaceAddress]"
  info "  circuitPath: path where circuit files will be placed."
  info "  rpcEndpoint: URL of web3 RPC endpoint."
  info "  marketplaceAddress: Address of deployed Codex marketplace contracts."

proc getCircuitHash(rpcEndpoint: string, marketplaceAddress: string): Future[?!string] {.async.} =
  let provider = JsonRpcProvider.new(rpcEndpoint)
  without address =? Address.init(marketplaceAddress):
    return failure("Invalid address: " & marketplaceAddress)

  let marketplace = Marketplace.new(address, provider)
  let config = await marketplace.config()
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

proc unzip(zipfile:string, targetPath: string): ?!void =
  var z: ZipArchive
  if not z.open(zipfile):
    return failure("Unable to open zip file: " & zipfile)
  z.extractAll(targetPath)
  z.close()
  success()

proc main() {.async.} =
  info "Codex Circuit Downloader, Aww yeah!"
  let args = os.commandLineParams()
  if args.len != 3:
    printHelp()
    return

  let
    circuitPath = args[0]
    rpcEndpoint = args[1]
    marketplaceAddress = args[2]
    zipfile = circuitPath / "circuit.zip"

  debug "Starting", circuitPath, rpcEndpoint, marketplaceAddress

  discard existsOrCreateDir(circuitPath)

  without circuitHash =? (await getCircuitHash(rpcEndpoint, marketplaceAddress)), err:
    error "Failed to get circuit hash", msg = err.msg
    return
  debug "Got circuithash", circuitHash

  let url = formatUrl(circuitHash)
  if dlErr =? (await downloadZipfile(url, zipfile)).errorOption:
    error "Failed to download circuit file", msg = dlErr.msg
    return
  debug "Download completed"

  if err =? unzip(zipfile, circuitPath).errorOption:
    error "Failed to unzip file", msg = err.msg
    return
  debug "Unzip completed"

  removeFile(zipfile)

when isMainModule:
  waitFor main()
  info "Done!"
