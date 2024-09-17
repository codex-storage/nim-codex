import std/strformat
import pkg/questionable
import pkg/questionable/results

type
  ValidationGroups* = range[2..65535]
  MaxSlots* = Positive
  ValidationParams* = object
    maxSlots: MaxSlots
    groups: ?ValidationGroups
    groupIndex: uint16

func init*(
  _: type ValidationParams, 
  maxSlots: MaxSlots,
  groups: ?ValidationGroups,
  groupIndex: uint16
): ?!ValidationParams =
  if validationGroups =? groups and groupIndex >= uint16(validationGroups):
    return failure fmt"The value of the group index must be less than validation groups! (got: {groupIndex = }, groups = {validationGroups})"
  
  success ValidationParams(maxSlots: maxSlots, groups: groups, groupIndex: groupIndex)

func maxSlots*(validationParams: ValidationParams): MaxSlots =
  validationParams.maxSlots

func groups*(validationParams: ValidationParams): ?ValidationGroups =
  validationParams.groups

func groupIndex*(validationParams: ValidationParams): uint16 =
  validationParams.groupIndex
