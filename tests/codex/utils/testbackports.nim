## A module to test codex/utils/backports.nim.  Code formatting is unorthodox to
## keep "diffs" between a version here and the one in mainline hopefully small.
import std/unittest
import codex/utils/backports

when true:      # Block for parseSize; indented to match mainline
  var sz: int64
  template checkParseSize(s, expectLen, expectVal) =
    let got = parseSize(s, sz)
    check got == expectLen
    check sz  == expectVal

suite "backports":
 test "checking parseSize":
  #              STRING    LEN SZ
  # Good, complete parses
  checkParseSize "1  b"   , 4, 1
  checkParseSize "1  B"   , 4, 1
  checkParseSize "1k"     , 2, 1000
  checkParseSize "1 kib"  , 5, 1024
  checkParseSize "1 ki"   , 4, 1024
  checkParseSize "1mi"    , 3, 1048576
  checkParseSize "1 mi"   , 4, 1048576
  checkParseSize "1 mib"  , 5, 1048576
  checkParseSize "1 Mib"  , 5, 1048576
  checkParseSize "1 MiB"  , 5, 1048576
  checkParseSize "1.23GiB", 7, 1320702444 # 1320702443.52 rounded
  checkParseSize "0.001k" , 6, 1
  checkParseSize "0.0004k", 7, 0
  checkParseSize "0.0006k", 7, 1
  # Incomplete parses
  checkParseSize "1  "    , 1, 1          # Trailing white IGNORED
  checkParseSize "1  B "  , 4, 1          # Trailing white IGNORED
  checkParseSize "1  B/s" , 4, 1          # Trailing junk IGNORED
  checkParseSize "1 kX"   , 3, 1000
  checkParseSize "1 kiX"  , 4, 1024
  checkParseSize "1j"     , 1, 1          # Unknown prefix IGNORED
  checkParseSize "1 jib"  , 2, 1          # Unknown prefix post space
  checkParseSize "1  ji"  , 3, 1
  # Bad parses; `sz` should stay last good|incomplete value
  checkParseSize "-1b"    , 0, 1          # Negative numbers
  checkParseSize "abc"    , 0, 1          # Non-numeric
  checkParseSize " 12"    , 0, 1          # Leading white
  # Value Edge cases
  checkParseSize "9223372036854775807", 19, int64.high
