import std/hashes
import pkg/nimcrypto
import ../logging

type PurchaseId* = distinct array[32, byte]

chronicles.formatIt(PurchaseId): it.short0xHexLog

proc hash*(x: PurchaseId): Hash {.borrow.}
proc `==`*(x, y: PurchaseId): bool {.borrow.}
proc toHex*(x: PurchaseId): string = array[32, byte](x).toHex
