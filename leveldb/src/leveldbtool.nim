import options, os, strutils
import leveldb

proc tool() =
  proc usage() =
    echo "LevelDB client"
    echo ""
    echo "Usage:"
    echo "  leveldb [-d <db_path>] create"
    echo "  leveldb [-d <db_path>] get <key> [-x | --hex]"
    echo "  leveldb [-d <db_path>] put <key> <value> [-x | --hex]"
    echo "  leveldb [-d <db_path>] list [-x | --hex]"
    echo "  leveldb [-d <db_path>] keys"
    echo "  leveldb [-d <db_path>] delete <key>"
    echo "  leveldb [-d <db_path>] repair"
    echo "  leveldb -h | --help"
    echo "  leveldb -v | --version"
    echo ""
    echo "Options:"
    echo "  -d --database  Database path"
    echo "  -x --hex       binary value in uppercase hex"
    echo "  -h --help      Show this screen"
    echo "  -v --version   Show version"
    quit()

  var args = commandLineParams()

  if "-h" in args or "--help" in args or len(args) == 0:
    usage()

  if "-v" in args or "--version" in args:
    echo "leveldb.nim ", version
    let (major, minor) = getLibVersion()
    echo "leveldb ", major, ".", minor
    quit()

  proc findArg(s: seq[string], item: string): int =
    result = find(s, item)
    let stop = find(s, "--")
    if stop >= 0 and stop <= result:
      result = -1

  var dbPath = "./"
  var i = findArg(args, "-d")
  var j = findArg(args, "--database")
  if i >= 0 and j >= 0:
    quit("Please specify database path one time only.")
  i = max(i, j)
  if i >= 0:
    if (i + 1) < len(args):
      dbPath = args[i+1]
      args.delete(i+1)
      args.delete(i)
    else:
      quit("Please specify database path.")

  var hex = false
  i = findArg(args, "-x")
  j = findArg(args, "--hex")
  if i >= 0:
    hex = true
    args.delete(i)
  if j >= 0:
    hex = true
    args.delete(j)

  # drop stop word
  if "--" in args:
    args.delete(args.find("--"))

  if len(args) == 0:
    usage()

  proc checkCommand(args: seq[string], requires: int) =
    if len(args) < requires + 1:
      quit("Command " & args[0] & " requires at least " & $(requires) & " arguments.")


  var db: LevelDb
  var key, value: string
  if args[0] == "create":
    db = leveldb.open(dbPath)
    db.close()
  elif args[0] == "get":
    checkCommand(args, 1)
    db = leveldb.open(dbPath)
    key = args[1]
    let val = db.get(key)
    if val.isNone():
      quit()
    else:
      if hex:
        echo val.get().toHex()
      else:
        echo val.get()
    db.close()
  elif args[0] == "put":
    checkCommand(args, 2)
    db = leveldb.open(dbPath)
    key = args[1]
    value = args[2]
    if hex:
      value = parseHexStr(value)
    db.put(key, value)
    db.close()
  elif args[0] == "list":
    db = leveldb.open(dbPath)
    for key, value in db.iter():
      if hex:
        echo key, " ", value.toHex()
      else:
        echo key, " ", value
    db.close()
  elif args[0] == "keys":
    db = leveldb.open(dbPath)
    for key, value in db.iter():
      echo key
    db.close()
  elif args[0] == "delete":
    checkCommand(args, 1)
    db = leveldb.open(dbPath)
    key = args[1]
    db.delete(key)
    db.close()
  elif args[0] == "repair":
    repairDb(dbPath)

when isMainModule:
  tool()
