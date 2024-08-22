import std/os

proc printHelp() = 
  echo "Usage: ./cirdl [circuitPath] [rpcEndpoint] [marketplaceAddress]"
  echo "  circuitPath: path where circuit files will be placed."
  echo "  rpcEndpoint: URL of web3 RPC endpoint."
  echo "  marketplaceAddress: Address of deployed Codex marketplace contracts."

proc getCircuitHash(rpcEndpoint: string, marketplaceAddress: string): string =
  return "A"

proc formatUrl(hash: string): string =
  return "A"

proc downloadZipfile(url: string, filepath: string) =
  echo "a"

proc unzip(zipfile:string, targetPath: string) = 
  echo "a"

proc main() =
  echo "Codex Circuit Downloader, Aww yeah!"
  let args = os.commandLineParams()
  if args.len != 3:
    printHelp()
    return

  let
    circuitPath = args[0]
    rpcEndpoint = args[1]
    marketplaceAddress = args[2]
    zipfile = circuitPath / "circuit.zip"

  let
    circuitHash = getCircuitHash(rpcEndpoint, marketplaceAddress)
    url = formatUrl(circuitHash)

  downloadZipfile(url, zipfile)
  unzip(zipfile, circuitPath)
  removeFile(zipfile)

  echo "Done!"

when isMainModule:
  main()
