import std/os
import pkg/chronicles
import pkg/chronos
import pkg/ethers
import pkg/questionable
import pkg/questionable/results
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
  return "A"

proc downloadZipfile(url: string, filepath: string) =
  info "a"

proc unzip(zipfile:string, targetPath: string) = 
  info "a"

proc main() {.async.} =
  info "Codex Circuit Downloader, Aww yeah!"
  let args = os.commandLineParams()
  if args.len != 3:
    printHelp()
    return

  let
    circuitPath = args[0]
    rpcEndpoint = "http://kubernetes.docker.internal:30001" #args[1]
    marketplaceAddress = "0x111F5aAA5DFF76510b220d152426fe878B4a87AE" #args[2]
    zipfile = circuitPath / "circuit.zip"

  without circuitHash =? (await getCircuitHash(rpcEndpoint, marketplaceAddress)), err:
    error "Failed to get circuit hash", msg = err.msg
    return
  info "got circuitHash", circuitHash

  let url = formatUrl(circuitHash)

  downloadZipfile(url, zipfile)
  unzip(zipfile, circuitPath)
  removeFile(zipfile)

when isMainModule:
  waitFor main()
  info "Done!"
