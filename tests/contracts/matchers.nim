import std/json
import std/strutils
import pkg/asynctest
import pkg/ethers

proc revertReason*(e: ref ValueError): string =
  try:
    let json = parseJson(e.msg)
    var msg = json{"message"}.getStr
    const revertPrefix =
      "Error: VM Exception while processing transaction: reverted with " &
      "reason string "
    msg = msg.replace(revertPrefix)
    msg = msg.replace("\'", "")
    return msg
  except JsonParsingError:
    return ""


template revertsWith*(reason, body) =
  var revertReason = ""
  try:
    body
  except ValueError as e:
    revertReason = e.revertReason
  check revertReason == reason