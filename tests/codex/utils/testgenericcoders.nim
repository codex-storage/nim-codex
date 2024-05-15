import std/unittest
import pkg/questionable
import pkg/questionable/results
import pkg/codex/utils/genericcoders
import ../helpers

type
  MyEnum = enum
    MyEnumA = 1
    MyEnumB = 2

  MyObj = object
    a: int
    b: string
    c: bool
    d: MyEnum
    e: seq[int]

  MyTuple = (int, string, bool, MyEnum, seq[int])

proc `==`*(a, b: MyObj): bool =
  (a.a == b.a) and
    (a.b == b.b) and
    (a.c == b.c) and
    (a.d == b.d) and
    (a.e == b.e)

proc `$`*(a: MyObj): string =
  "a: " & $a.a &
    ", b: " & $a.b &
    ", c: " & $a.c &
    ", d: " & $a.d &
    ", e: " & $a.e

checksuite "Test encode/decode":
  proc coderTest(T: type, a: T) =
    let bytes = a.encode

    without decoded =? T.decode(bytes), err:
      fail

    check:
      decoded == a

  test "Should encode and decode primitive values":
    coderTest(int, 123)
    coderTest(int, -123)
    coderTest(int64, 123.int64)
    coderTest(int64, -123.int64)
    coderTest(Natural, 123.Natural)
    coderTest(NBytes, 123.KiBs)
    coderTest(string, "")
    coderTest(string, "123")
    coderTest(string, "abcdefghij")
    coderTest(bool, false)
    coderTest(bool, true)
    coderTest(MyEnum, MyEnumA)
    coderTest(MyEnum, MyEnumB)
    coderTest(seq[int], @[1, 2, 3])
    coderTest(seq[int], newSeq[int]())

checksuite "Test autoencode/autodecode":
  proc autocoderTest(T: type, a: T) =
    let bytes = a.autoencode

    without decoded =? T.autodecode(bytes), err:
      fail

    check:
      decoded == a

  test "Should encode and decode product values":
    autocoderTest(MyObj, MyObj(a: 1, b: "abc", c: true, d: MyEnumA, e: @[1, 2, 3]))
    autocoderTest(MyTuple, (2, "def", false, MyEnumB, newSeq[int]()))
