import std/strformat
import pkg/questionable
import pkg/questionable/results

type
  ValidationParams* = object
    maxSlots: int
    partitionSize: int
    partitionIndex: int

func init*(
  _: type ValidationParams, 
  maxSlots: int,
  partitionSize: int,
  partitionIndex: int
): ?!ValidationParams =
  if partitionSize <= 0:
    return failure fmt"Partition size must be greater than 0! (got: {partitionSize = })"
  if partitionIndex < 0:
    return failure fmt"Partition index must be greater than or equal to 0! (got: {partitionIndex = })"
  if partitionIndex >= partitionSize:
    return failure fmt"The value of the partition index must be less than partition size! (got: {partitionIndex = }, {partitionSize = })"
  if maxSlots <= 0:
    return failure fmt"maxSlots must be greater than 0! (got: {maxSlots = })"
  success ValidationParams(maxSlots: maxSlots, partitionSize: partitionSize, partitionIndex: partitionIndex)

func maxSlots*(validationParams: ValidationParams): int =
  validationParams.maxSlots

func partitionSize*(validationParams: ValidationParams): int =
  validationParams.partitionSize

func partitionIndex*(validationParams: ValidationParams): int =
  validationParams.partitionIndex
