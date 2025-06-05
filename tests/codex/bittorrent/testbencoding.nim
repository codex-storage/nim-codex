import std/strformat
import std/sequtils

import pkg/unittest2
import pkg/nimcrypto
import pkg/stew/byteutils
import pkg/questionable

import ../../examples
import ../../../codex/bittorrent/bencoding

type ExampleObject* = ref object
  length*: uint64
  pieceLength*: uint32
  pieces*: seq[seq[byte]]
  name*: ?string

func bencode(obj: ExampleObject): seq[byte] =
  # flatten pieces
  var pieces: seq[byte]
  for piece in obj.pieces:
    pieces.add(piece)
  result = @['d'.byte]
  result.add(bencode("length") & bencode(obj.length))
  if name =? obj.name:
    result.add(bencode("name") & bencode(name))
  result.add(bencode("piece length") & bencode(obj.pieceLength))
  result.add(bencode("pieces") & bencode(pieces))
  result.add('e'.byte)

proc toString(bytes: seq[byte]): string =
  result = newStringOfCap(len(bytes))
  for b in bytes:
    add(result, b.char)

proc checkEncoding(actual: seq[byte], expected: string) =
  check actual.toString == expected

suite "b-encoding":
  test "int":
    checkEncoding(bencode(1'i8), "i1e")
    checkEncoding(bencode(-1'i8), "i-1e")
    checkEncoding(bencode(int8.low), fmt"i{int8.low}e")
    checkEncoding(bencode(int8.high), fmt"i{int8.high}e")
    checkEncoding(bencode(uint8.low), fmt"i{uint8.low}e")
    checkEncoding(bencode(uint8.high), fmt"i{uint8.high}e")
    checkEncoding(bencode(int16.low), fmt"i{int16.low}e")
    checkEncoding(bencode(int16.high), fmt"i{int16.high}e")
    checkEncoding(bencode(uint16.low), fmt"i{uint16.low}e")
    checkEncoding(bencode(uint16.high), fmt"i{uint16.high}e")
    checkEncoding(bencode(int32.low), fmt"i{int32.low}e")
    checkEncoding(bencode(int32.high), fmt"i{int32.high}e")
    checkEncoding(bencode(uint32.low), fmt"i{uint32.low}e")
    checkEncoding(bencode(uint32.high), fmt"i{uint32.high}e")
    checkEncoding(bencode(uint.high), fmt"i{uint.high}e")
    checkEncoding(bencode(int64.low), fmt"i{int64.low}e")
    checkEncoding(bencode(int64.high), fmt"i{int64.high}e")
    checkEncoding(bencode(uint64.low), fmt"i{uint64.low}e")
    checkEncoding(bencode(uint64.high), fmt"i{uint64.high}e")
    checkEncoding(bencode(int.low), fmt"i{int.low}e")
    checkEncoding(bencode(int.high), fmt"i{int.high}e")

  test "empty buffer":
    let input: array[0, byte] = []
    check bencode(input) == "0:".toBytes

  test "buffer":
    let input = [1.byte, 2, 3]
    check bencode(input) == fmt"{input.len}:".toBytes() & @input

  test "longer buffer":
    let input = toSeq(1.byte .. 127.byte)
    check bencode(input) == fmt"{input.len}:".toBytes() & @input

  test "string":
    let input = "abc"
    check bencode(input) == "3:abc".toBytes

  test "longer string":
    let input = exampleString(127)
    check bencode(input) == fmt"{input.len}:{input}".toBytes

  test "empty string":
    let input = ""
    check bencode(input) == "0:".toBytes

  test "empty list":
    let input: seq[string] = @[]
    check bencode(input) == "le".toBytes

  test "list (of strings)":
    let input = ["abc", "def"]
    check bencode(input) == "l3:abc3:defe".toBytes

  test "list (of seq[byte])":
    let seq1 = toSeq(1.byte .. 127.byte)
    let seq2 = toSeq(128.byte .. 150.byte)
    let input = [seq1, seq2]
    check bencode(input) ==
      fmt"l{seq1.len}:".toBytes & seq1 & fmt"{seq2.len}:".toBytes & seq2 & @['e'.byte]

  test "list (of integers)":
    let input = [1, -2, 3, 0x7f, -0x80, 0xff]
    check bencode(input) == "li1ei-2ei3ei127ei-128ei255ee".toBytes

  test "custom type":
    let piece = "1cc46da027e7ff6f1970a2e58880dbc6a08992a0".hexToSeqByte
    let obj = ExampleObject(
      length: 40960, pieceLength: 65536, pieces: @[piece], name: "data40k.bin".some
    )
    let encoded = bencode(obj)
    check encoded ==
      "d6:lengthi40960e4:name11:data40k.bin12:piece lengthi65536e6:pieces20:".toBytes &
      piece & @['e'.byte]
    let expectedInfoHash = "1902d602db8c350f4f6d809ed01eff32f030da95"
    check $sha1.digest(encoded) == expectedInfoHash.toUpperAscii
