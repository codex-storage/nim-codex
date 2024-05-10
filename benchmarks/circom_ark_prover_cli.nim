import std/[sequtils, strformat, os, options, importutils]
import std/[times, os, strutils, terminal, parseopt]

import pkg/questionable
import pkg/questionable/results
import pkg/datastore

import pkg/codex/[rng, stores, merkletree, codextypes, slots]
import pkg/codex/utils/[json, poseidon2digest]
import pkg/codex/slots/[builder, sampler/utils, backends/helpers]
import pkg/constantine/math/[arithmetic, io/io_bigints, io/io_fields]

import ./utils
import ./create_circuits

type CircomCircuit* = object
  r1cs*: string
  wasm*: string
  zkey*: string
  inputs*: string
  dir*: string
  circName*: string
  backendCfg: ptr CircomBn254Cfg
  vkp*: ptr VerifyingKey

proc release*(self: CircomCompat) =
  ## Release the ctx
  ##

  if not isNil(self.backendCfg):
    self.backendCfg.unsafeAddr.releaseCfg()

  if not isNil(self.vkp):
    self.vkp.unsafeAddr.release_key()

proc prove*[H](self: CircomCompat, input: ProofInputs[H]): ?!CircomProof =
  ## Encode buffers using a ctx
  ##

  # NOTE: All inputs are statically sized per circuit
  # and adjusted accordingly right before being passed
  # to the circom ffi - `setLen` is used to adjust the
  # sequence length to the correct size which also 0 pads
  # to the correct length
  doAssert input.samples.len == self.numSamples, "Number of samples does not match"

  doAssert input.slotProof.len <= self.datasetDepth,
    "Number of slot proofs does not match"

  doAssert input.samples.allIt(
    block:
      (
        it.merklePaths.len <= self.slotDepth + self.blkDepth and
        it.cellData.len <= self.cellElms * 32
      )
  ), "Merkle paths length does not match"

  # TODO: All parameters should match circom's static parametter
  var ctx: ptr CircomCompatCtx

  defer:
    if ctx != nil:
      ctx.addr.releaseCircomCompat()

  if initCircomCompat(self.backendCfg, addr ctx) != ERR_OK or ctx == nil:
    raiseAssert("failed to initialize CircomCompat ctx")

  var
    entropy = input.entropy.toBytes
    dataSetRoot = input.datasetRoot.toBytes
    slotRoot = input.slotRoot.toBytes

  if ctx.pushInputU256Array("entropy".cstring, entropy[0].addr, entropy.len.uint32) !=
      ERR_OK:
    return failure("Failed to push entropy")

  if ctx.pushInputU256Array(
    "dataSetRoot".cstring, dataSetRoot[0].addr, dataSetRoot.len.uint32
  ) != ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU256Array("slotRoot".cstring, slotRoot[0].addr, slotRoot.len.uint32) !=
      ERR_OK:
    return failure("Failed to push data set root")

  if ctx.pushInputU32("nCellsPerSlot".cstring, input.nCellsPerSlot.uint32) != ERR_OK:
    return failure("Failed to push nCellsPerSlot")

  if ctx.pushInputU32("nSlotsPerDataSet".cstring, input.nSlotsPerDataSet.uint32) !=
      ERR_OK:
    return failure("Failed to push nSlotsPerDataSet")

  if ctx.pushInputU32("slotIndex".cstring, input.slotIndex.uint32) != ERR_OK:
    return failure("Failed to push slotIndex")

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

proc toCircomInputs*(inputs: ProofInputs[Poseidon2Hash]): Inputs =
  var
    slotIndex = inputs.slotIndex.toF.toBytes.toArray32
    datasetRoot = inputs.datasetRoot.toBytes.toArray32
    entropy = inputs.entropy.toBytes.toArray32

    elms = [entropy, datasetRoot, slotIndex]

  let inputsPtr = allocShared0(32 * elms.len)
  copyMem(inputsPtr, addr elms[0], elms.len * 32)

  CircomInputs(elms: cast[ptr array[32, byte]](inputsPtr), len: elms.len.uint)

proc verify*(self: CircomCompat, proof: CircomProof, inputs: ProofInputs[H]): ?!bool =
  ## Verify a proof using a ctx
  ##

  var
    proofPtr = unsafeAddr proof
    inputs = inputs.toCircomInputs()

  try:
    let res = verifyCircuit(proofPtr, inputs.addr, self.vkp)
    if res == ERR_OK:
      success true
    elif res == ERR_FAILED_TO_VERIFY_PROOF:
      success false
    else:
      failure("Failed to verify proof - err code: " & $res)
  finally:
    inputs.releaseCircomInputs()

proc init*(
    _: type CircomCompat,
    r1csPath: string,
    wasmPath: string,
    zkeyPath: string = "",
    slotDepth = DefaultMaxSlotDepth,
    datasetDepth = DefaultMaxDatasetDepth,
    blkDepth = DefaultBlockDepth,
    cellElms = DefaultCellElms,
    numSamples = DefaultSamplesNum,
): CircomCompat =
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

  CircomCompat(
    r1csPath: r1csPath,
    wasmPath: wasmPath,
    zkeyPath: zkeyPath,
    slotDepth: slotDepth,
    datasetDepth: datasetDepth,
    blkDepth: blkDepth,
    cellElms: cellElms,
    numSamples: numSamples,
    backendCfg: cfg,
    vkp: vkpPtr,
  )

proc runArkCircom(
    args: CircuitArgs, files: CircomCircuit, proofInputs: ProofInputs[Poseidon2Hash]
) =
  echo "Loading sample proof..."
  var circom = CircomCompat.init(
    files.r1cs,
    files.wasm,
    files.zkey,
    slotDepth = args.depth,
    numSamples = args.nsamples,
  )
  defer:
    circom.release() # this comes from the rust FFI

  echo "Sample proof loaded..."
  echo "Proving..."

  var proof: CircomProof = circom.prove(proofInputs).tryGet

  var verRes: bool = circom.verify(proof, proofInputs).tryGet
  if not verRes:
    echo "verification failed"
    quit 100

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

proc parseCliOptions(args: var CircuitArgs, files: var CircomCircuit) =
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
        files.r1cs = value.expectPath()
      of "wasm":
        files.wasm = value.expectPath()
      of "zkey":
        files.zkey = value.expectPath()
      of "inputs":
        files.inputs = value.expectPath()
      of "dir":
        files.dir = value.expectPath()
      of "name":
        files.circName = value
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
    files = CircomCircuit()

  parseCliOptions(args, files)

  let dir =
    if files.dir != "":
      files.dir
    else:
      getCurrentDir()
  if files.circName != "":
    if files.r1cs == "":
      files.r1cs = dir / fmt"{files.circName}.r1cs"
    if files.wasm == "":
      files.wasm = dir / fmt"{files.circName}.wasm"
    if files.zkey == "":
      files.zkey = dir / fmt"{files.circName}.zkey"

  if files.inputs == "":
    files.inputs = dir / fmt"input.json"

  echo "Got file args: ", files

  var fileErrors = false
  template checkFile(file, name: untyped) =
    if file == "" or not file.fileExists():
      echo "\nERROR: must provide `" & name & "` file"
      fileErrors = true

  checkFile files.inputs, "inputs.json"
  checkFile files.r1cs, "r1cs"
  checkFile files.wasm, "wasm"
  checkFile files.zkey, "zkey"

  if fileErrors:
    echo "ERROR: couldn't find all files"
    printHelp()

  var
    inputData = files.inputs.readFile()
    inputs: JsonNode = !JsonNode.parse(inputData)

  # sets default values for these args
  if args.depth == 0:
    args.depth = codextypes.DefaultMaxSlotDepth
    # maximum depth of the slot tree
  if args.maxslots == 0:
    args.maxslots = 256
    # maximum number of slots

  # sets number of samples to take
  if args.nsamples == 0:
    args.nsamples = 1
    # number of samples to prove

  # overrides the input.json params
  if args.entropy != 0:
    inputs["entropy"] = %($args.entropy)
  if args.nslots != 0:
    inputs["nSlotsPerDataSet"] = %args.nslots
  if args.index != 0:
    inputs["slotIndex"] = %args.index
  if args.ncells != 0:
    inputs["nCellsPerSlot"] = %args.ncells

  var proofInputs = Poseidon2Hash.jsonToProofInput(inputs)

  echo "Got args: ", args
  runArkCircom(args, files, proofInputs)

when isMainModule:
  run()
