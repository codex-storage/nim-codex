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

type CircuitFiles* = object
  r1cs*: string
  wasm*: string
  zkey*: string
  inputs*: string
  dir*: string
  circName*: string

proc runArkCircom(args: CircuitArgs, files: CircuitFiles, inputs: JsonNode) =
  echo "Loading sample proof..."
  var
    proofInputs = Poseidon2Hash.jsonToProofInput(inputs)
    circom = CircomCompat.init(
      files.r1cs,
      files.wasm,
      files.zkey,
      slotDepth = args.depth,
      numSamples = args.nsamples,
      # datasetDepth  : int     # max depth of dataset  tree
      # blkDepth      : int     # depth of the block merkle tree (pow2 for now)
      # cellElms      : int     # number of field elements per cell
    )
  defer:
    circom.release() # this comes from the rust FFI

  echo "Sample proof loaded..."
  echo "Proving..."

  var proof: CircomProof
  benchmark fmt"prover":
    proof = circom.prove(proofInputs).tryGet

  var verRes: bool
  benchmark fmt"verify":
    verRes = circom.verify(proof, proofInputs).tryGet
  echo "verify result: ", verRes

proc printHelp() =
  echo "usage:"
  echo "  ./codex_ark_prover_cli [options] --output=proof_input.json --circom=proof_main.circom"
  echo ""
  echo "available options:"
  echo " -h, --help                         : print this help"
  echo " -v, --verbose                      : verbose output (print the actual parameters)"
  echo " -d, --depth      = <maxdepth>      : maximum depth of the slot tree (eg. 32)"
  echo " -N, --maxslots   = <maxslots>      : maximum number of slots (eg. 256)"
  echo " -c, --cellsize   = <cellSize>      : cell size in bytes (eg. 2048)"
  echo " -b, --blocksize  = <blockSize>     : block size in bytes (eg. 65536)"
  echo " -s, --nslots     = <nslots>        : number of slots in the dataset (eg. 13)"
  echo " -n, --nsamples   = <nsamples>      : number of samples we prove (eg. 100)"
  echo " -e, --entropy    = <entropy>       : external randomness (eg. 1234567)"
  echo " -S, --seed       = <seed>          : seed to generate the fake data (eg. 12345)"
  echo " -f, --file       = <datafile>      : slot data file, base name (eg. \"slotdata\" would mean \"slotdata5.dat\" for slot index = 5)"
  echo " -i, --index      = <slotIndex>     : index of the slot (within the dataset) we prove"
  echo " -k, --log2ncells = <log2(ncells)>  : log2 of the number of cells inside this slot (eg. 10)"
  echo " -K, --ncells     = <ncells>        : number of cells inside this slot (eg. 1024; must be a power of two)"
  echo " -o, --output     = <input.json>    : the JSON file into which we write the proof input"
  echo " -C, --circom     = <main.circom>   : the circom main component to create with these parameters"
  echo ""

  quit(1)

proc parseCliOptions(args: var CircuitArgs, files: var CircuitFiles) =

  var argCtr: int = 0

  for kind, key, value in getOpt():
    case kind

    # Positional arguments
    of cmdArgument:
      printHelp()

    # Switches
    of cmdLongOption, cmdShortOption:
      case key

      of "h", "help"      : printHelp()
      of "d", "depth"     : args.depth         = parseInt(value) 
      of "N", "maxslots"  : args.maxslots      = parseInt(value)
      of "c", "cellsize"  : args.cellsize      = checkPowerOfTwo(parseInt(value),"cellSize")
      of "b", "blocksize" : args.blocksize     = checkPowerOfTwo(parseInt(value),"blockSize")
      of "n", "nsamples"  : args.nsamples      = parseInt(value)
      of "e", "entropy"   : args.entropy       = parseInt(value)
      of "S", "seed"      : args.seed        = parseInt(value)
      of "s", "nslots"    : args.nslots        = parseInt(value)
      of "K", "ncells"    : args.ncells        = checkPowerOfTwo(parseInt(value),"nCells")
      of "i", "index"     : args.index         = parseInt(value)

      of "r1cs"           : files.r1cs = value.absolutePath
      of "wasm"           : files.wasm = value.absolutePath
      of "zkey"           : files.zkey = value.absolutePath
      of "inputs"         : files.inputs = value.absolutePath
      of "dir"            : files.dir = value.absolutePath
      of "name"           : files.circName = value

      else:
        echo "Unknown option: ", key
        echo "use --help to get a list of options"
        quit()

    of cmdEnd:
      discard  

proc run*() =
  echo "Running benchmark"

  # prove wasm ${CIRCUIT_MAIN}.zkey witness.wtns proof.json public.json

  var
    args = CircuitArgs()
    files = CircuitFiles()

  parseCliOptions(args, files)

  let dir = if files.dir != "": files.dir else: getCurrentDir()
  if files.circName != "":
    if files.r1cs == "": files.r1cs = dir / fmt"{files.circName}.r1cs"
    if files.wasm == "": files.wasm = dir / fmt"{files.circName}.wasm"
    if files.zkey == "": files.zkey = dir / fmt"{files.circName}.zkey"

  if files.inputs == "": files.inputs = dir / fmt"input.json"

  var
    inputData = files.inputs.readFile()
    inputs = !JsonNode.parse(inputData)

  if args.depth == 0:     args.depth = codextypes.DefaultMaxSlotDepth # maximum depth of the slot tree
  if args.maxslots == 0:  args.maxslots = 256 # maximum number of slots
  if args.cellsize == 0:  args.cellsize = codextypes.DefaultCellSize.int # cell size in bytes
  if args.blocksize == 0: args.blocksize = codextypes.DefaultBlockSize.int # block size in bytes
  if args.nsamples == 0:  args.nsamples = 1 # number of samples to prove
  if args.entropy == 0:   args.entropy = inputs.entropy # external randomness
  if args.seed == 0:      args.seed = inputs.seed # seed for creating fake data
  if args.nslots == 0:    args.nslots = inputs.nSlotsPerDataSet # number of slots in the dataset
  if args.index == 0:     args.index = inputs.slotIndex # which slot we prove (0..NSLOTS-1)
  if args.ncells == 0:    args.ncells = inputs.nCellsPerSlot # number of cells in this slot

  echo "Got args: ", args
  echo "Got files: ", files
  # runArkCircom(args, files)

when isMainModule:
  run()
