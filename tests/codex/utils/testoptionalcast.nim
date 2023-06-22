import std/unittest
import codex/utils/optionalcast
import ../helpers

checksuite "optional casts":
  test "casting value to same type works":
    check 42 as int == some 42

  test "casting value to unrelated type evaluates to None":
    check 42 as string == string.none

  test "casting value to subtype works":
    type
      BaseType = ref object of RootObj
      SubType = ref object of BaseType
    let x: BaseType = SubType()
    check x as SubType == SubType(x).some

  test "casting to unrelated subtype evaluates to None":
    type
      BaseType = ref object of RootObj
      SubType = ref object of BaseType
      OtherType = ref object of BaseType
    let x: BaseType = SubType()
    check x as OtherType == OtherType.none

  test "casting works on optional types":
    check 42.some as int == some 42
    check 42.some as string == string.none
    check int.none as int == int.none
