import pkg/contractabi
import pkg/ethers/fields
import pkg/questionable/results

export contractabi

const DefaultRequestCacheSize* = 128.uint16
const DefaultMaxPriorityFeePerGas* = 1_000_000_000.uint64

type
  MarketplaceConfig* = object
    collateral*: CollateralConfig
    proofs*: ProofConfig
    reservations*: SlotReservationsConfig
    requestDurationLimit*: uint64

  CollateralConfig* = object
    repairRewardPercentage*: uint8
      # percentage of remaining collateral slot has after it has been freed
    maxNumberOfSlashes*: uint8 # frees slot when the number of slashes reaches this value
    slashPercentage*: uint8 # percentage of the collateral that is slashed
    validatorRewardPercentage*: uint8
      # percentage of the slashed amount going to the validators

  ProofConfig* = object
    period*: uint64 # proofs requirements are calculated per period (in seconds)
    timeout*: uint64 # mark proofs as missing before the timeout (in seconds)
    downtime*: uint8 # ignore this much recent blocks for proof requirements
    downtimeProduct*: uint8
    zkeyHash*: string # hash of the zkey file which is linked to the verifier
    # Ensures the pointer does not remain in downtime for many consecutive
    # periods. For each period increase, move the pointer `pointerProduct`
    # blocks. Should be a prime number to ensure there are no cycles.

  SlotReservationsConfig* = object
    maxReservations*: uint8

func fromTuple(_: type ProofConfig, tupl: tuple): ProofConfig =
  ProofConfig(
    period: tupl[0],
    timeout: tupl[1],
    downtime: tupl[2],
    downtimeProduct: tupl[3],
    zkeyHash: tupl[4],
  )

func fromTuple(_: type SlotReservationsConfig, tupl: tuple): SlotReservationsConfig =
  SlotReservationsConfig(maxReservations: tupl[0])

func fromTuple(_: type CollateralConfig, tupl: tuple): CollateralConfig =
  CollateralConfig(
    repairRewardPercentage: tupl[0],
    maxNumberOfSlashes: tupl[1],
    slashPercentage: tupl[2],
    validatorRewardPercentage: tupl[3],
  )

func fromTuple(_: type MarketplaceConfig, tupl: tuple): MarketplaceConfig =
  MarketplaceConfig(
    collateral: tupl[0],
    proofs: tupl[1],
    reservations: tupl[2],
    requestDurationLimit: tupl[3],
  )

func solidityType*(_: type SlotReservationsConfig): string =
  solidityType(SlotReservationsConfig.fieldTypes)

func solidityType*(_: type ProofConfig): string =
  solidityType(ProofConfig.fieldTypes)

func solidityType*(_: type CollateralConfig): string =
  solidityType(CollateralConfig.fieldTypes)

func solidityType*(_: type MarketplaceConfig): string =
  solidityType(MarketplaceConfig.fieldTypes)

func encode*(encoder: var AbiEncoder, slot: SlotReservationsConfig) =
  encoder.write(slot.fieldValues)

func encode*(encoder: var AbiEncoder, slot: ProofConfig) =
  encoder.write(slot.fieldValues)

func encode*(encoder: var AbiEncoder, slot: CollateralConfig) =
  encoder.write(slot.fieldValues)

func encode*(encoder: var AbiEncoder, slot: MarketplaceConfig) =
  encoder.write(slot.fieldValues)

func decode*(decoder: var AbiDecoder, T: type ProofConfig): ?!T =
  let tupl = ?decoder.read(ProofConfig.fieldTypes)
  success ProofConfig.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type SlotReservationsConfig): ?!T =
  let tupl = ?decoder.read(SlotReservationsConfig.fieldTypes)
  success SlotReservationsConfig.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type CollateralConfig): ?!T =
  let tupl = ?decoder.read(CollateralConfig.fieldTypes)
  success CollateralConfig.fromTuple(tupl)

func decode*(decoder: var AbiDecoder, T: type MarketplaceConfig): ?!T =
  let tupl = ?decoder.read(MarketplaceConfig.fieldTypes)
  success MarketplaceConfig.fromTuple(tupl)
