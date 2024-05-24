import std/[sequtils, strformat, os, options, importutils]
import std/[times, os, strutils, terminal, parseopt, json]

import pkg/questionable
import pkg/questionable/results

import pkg/circomcompat
import pkg/poseidon2/io

import ./utils
import ./create_circuits

type

  CircomCircuit* = object
    r1csPath*: string
    wasmPath*: string
    zkeyPath*: string
    inputsPath*: string
    dir*: string
    circName*: string
    backendCfg: ptr CircomBn254Cfg
    vkp*: ptr VerifyingKey

proc release*(self: CircomCircuit) =
  ## Release the ctx
  ##
  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.releaseCfg()
  if not isNil(self.vkp):
    self.vkp.unsafeAddr.release_key()

proc prove*[H](self: CircomCircuit, input: JsonNode): ?!Proof =
  ## Encode buffers using a ctx
  ##

  # TODO: All parameters should match circom's static parametter
  var ctx: ptr CircomCompatCtx

  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCircuit()

  if initCircomCompat(self.backendCfg, addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCircuit ctx")

  # if ctx.pushInputU256Array("entropy".cstring, entropy[0].addr, entropy.len.uint32) !=
  #     ERR_OK:
  #   return failure("Failed to push entropy")

  # if ctx.pushInputU32("slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
  #   return failure("Failed to push slotIndex")

  var slotProof = input.slotProof.mapIt(it.toBytes).concat

  slotProof.setLen(self.datasetDepth) # zero pad inputs to correct size

  # arrays are always flattened
  if ctx.pushInputU256Array(
    "slotProof".cstring, slotProof[0].addr, uint (slotProof[0].len * slotProof.len)
  ) != ERR_OK:
    return failure("Failed to push slot proof")

  for s in input.samples:
    var
      merklePaths = s.merklePaths.mapIt(it.toBytes)
      data = s.cellData

    merklePaths.setLen(self.slotDepth) # zero pad inputs to correct size
    if ctx.pushInputU256Array(
      "merklePaths".cstring,
      merklePaths[0].addr,
      uint (merklePaths[0].len * merklePaths.len),
    ) != ERR_OK:
      return failure("Failed to push merkle paths")

    data.setLen(self.cellElms * 32) # zero pad inputs to correct size
    if ctx.pushInputU256Array("cellData".cstring, data[0].addr, data.len.uint) != ERR_OK:
      return failure("Failed to push cell data")

  var proofPtr: ptr Proof = nil

  let proof =
    try:
      if (let res = self.backendCfg.proveCircuit(ctx, proofPtr.addr); res != ERR_OK) or
          proofPtr == nil:
        return failure("Failed to prove - err code: " & $res)

      proofPtr[]
    finally:
      if proofPtr != nil:
        proofPtr.addr.releaseProof()

  success proof

# proc toCircomInputs*(inputs: ProofInputs[Poseidon2Hash]): Inputs =
#   var
#     slotIndex = inputs.slotIndex.toF.toBytes.toArray32
#     datasetRoot = inputs.datasetRoot.toBytes.toArray32
#     entropy = inputs.entropy.toBytes.toArray32
#     elms = [entropy, datasetRoot, slotIndex]
#   let inputsPtr = allocShared0(32 * elms.len)
#   copyMem(inputsPtr, addr elms[0], elms.len * 32)
#   CircomInputs(elms: cast[ptr array[32, byte]](inputsPtr), len: elms.len.uint)

# proc verify*[H](self: CircomCircuit, proof: CircomProof, inputs: ProofInputs[H]): ?!bool =
#   ## Verify a proof using a ctx
#   ##
#   var
#     proofPtr = unsafeAddr proof
#     inputs = inputs.toCircomInputs()
#   try:
#     let res = verifyCircuit(proofPtr, inputs.addr, self.vkp)
#     if res == ERR_OK:
#       success true
#     elif res == ERR_FAILED_TO_VERIFY_PROOF:
#       success false
#     else:
#       failure("Failed to verify proof - err code: " & $res)
#   finally:
#     inputs.releaseCircomInputs()

proc init*(
    _: type CircomCircuit,
    r1csPath: string,
    wasmPath: string,
    zkeyPath: string = "",
): CircomCircuit =
  ## Create a new ctx
  ##

  var cfg: ptr CircomBn254Cfg
  var zkey = if zkeyPath.len > 0: zkeyPath.cstring else: nil

  if initCircomConfig(r1csPath.cstring, wasmPath.cstring, zkey, cfg.addr) != ERR_OK or
      cfg == nil:
    if cfg != nil:
      cfg.addr.releaseCfg()
    raiseAssert("failed to initialize circom compat config")

  var vkpPtr: ptr VerifyingKey = nil

  if cfg.getVerifyingKey(vkpPtr.addr) != ERR_OK or vkpPtr == nil:
    if vkpPtr != nil:
      vkpPtr.addr.releaseKey()
    raiseAssert("Failed to get verifying key")

  CircomCircuit(
    r1csPath: r1csPath,
    wasmPath: wasmPath,
    zkeyPath: zkeyPath,
    backendCfg: cfg,
    vkp: vkpPtr,
  )

proc printHelp() =
  echo "usage:"
  echo "  ./circom_ark_prover_cli [options] "
  echo ""
  echo "available options:"
  echo " -h, --help                         : print this help"
  echo " -v, --verbose                      : verbose output (print the actual parameters)"
  echo ""
  echo "Must provide files options. Use either:"
  echo "  --dir:$CIRCUIT_DIR --name:$CIRCUIT_NAME"
  echo "or:"
  echo "  --r1cs:$R1CS --wasm:$WASM --zkey:$ZKEY"
  echo ""

  quit(1)

proc parseCliOptions(args: var CircuitArgs, self: var CircomCircuit) =
  var argCtr: int = 0
  template expectPath(val: string): string =
    if val == "":
      echo "ERROR: expected path a but got empty for: ", key
      printHelp()
    val.absolutePath

  for kind, key, value in getOpt():
    case kind

    # Positional arguments
    of cmdArgument:
      echo "\nERROR: got unexpected arg: ", key, "\n"
      printHelp()

    # Switches
    of cmdLongOption, cmdShortOption:
      case key
      of "h", "help":
        printHelp()
      of "r1cs":
        self.r1csPath = value.expectPath()
      of "wasm":
        self.wasmPath = value.expectPath()
      of "zkey":
        self.zkeyPath = value.expectPath()
      of "inputs":
        self.inputsPath = value.expectPath()
      of "dir":
        self.dir = value.expectPath()
      of "name":
        self.circName = value
      else:
        echo "Unknown option: ", key
        echo "use --help to get a list of options"
        quit()
    of cmdEnd:
      discard

proc run*() =
  ## Run Codex Ark/Circom based prover
  ## 
  echo "Running prover"

  # prove wasm ${CIRCUIT_MAIN}.zkey witness.wtns proof.json public.json

  var
    args = CircuitArgs()
    self = CircomCircuit()

  parseCliOptions(args, self)

  let dir =
    if self.dir != "":
      self.dir
    else:
      getCurrentDir()
  if self.circName != "":
    if self.r1csPath == "":
      self.r1csPath = dir / fmt"{self.circName}.r1cs"
    if self.wasmPath == "":
      self.wasmPath = dir / fmt"{self.circName}.wasm"
    if self.zkeyPath == "":
      self.zkeyPath = dir / fmt"{self.circName}.zkey"

  if self.inputsPath == "":
    self.inputsPath = dir / fmt"input.json"

  echo "Got file args: ", self

  var fileErrors = false
  template checkFile(file, name: untyped) =
    if file == "" or not file.fileExists():
      echo "\nERROR: must provide `" & name & "` file"
      fileErrors = true

  checkFile self.inputsPath, "inputs.json"
  checkFile self.r1csPath, "r1cs"
  checkFile self.wasmPath, "wasm"
  checkFile self.zkeyPath, "zkey"

  if fileErrors:
    echo "ERROR: couldn't find all files"
    printHelp()

  var
    inputData = self.inputsPath.readFile()
    inputs: JsonNode = !JsonNode.parse(inputData)

  echo "Got args: ", args
  runArkCircom(args, self)

when isMainModule:
  run()
