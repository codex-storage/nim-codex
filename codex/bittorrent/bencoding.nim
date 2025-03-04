import std/strformat

import pkg/stew/byteutils

func bencode*(value: uint64): seq[byte] =
  fmt"i{value}e".toBytes

func bencode*(value: int64): seq[byte] =
  fmt"i{value}e".toBytes

func bencode*(value: openArray[byte]): seq[byte] =
  fmt"{value.len}:".toBytes & @value

func bencode*(value: string): seq[byte] =
  bencode(value.toBytes)

proc bencode*[T: not byte](value: openArray[T]): seq[byte] =
  fmt"l{value.mapIt(bencode(it).toString).join}e".toBytes
