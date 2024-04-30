import unittest, options, os, osproc, sequtils, strutils
import leveldb, leveldb/raw

const
  tmpDir = "/tmp/testleveldb"
  tmpNimbleDir = tmpDir / "nimble"
  tmpDbDir = tmpDir / "testdb"

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  block:
    let lastDir = getCurrentDir()
    setCurrentDir(dir)
    body
    setCurrentDir(lastDir)

proc execNimble(args: varargs[string]): tuple[output: string, exitCode: int] =
  var quotedArgs = @args
  quotedArgs.insert("-y")
  quotedArgs.insert("--nimbleDir:" & tmpNimbleDir)
  quotedArgs.insert("nimble")
  quotedArgs = quotedArgs.map(proc (x: string): string = "\"" & x & "\"")

  let cmd = quotedArgs.join(" ")
  result = execCmdEx(cmd)
  checkpoint(cmd)
  checkpoint(result.output)

proc execTool(args: varargs[string]): tuple[output: string, exitCode: int] =
  var quotedArgs = @args
  quotedArgs.insert(tmpDbDir)
  quotedArgs.insert("--database")
  quotedArgs.insert(tmpNimbleDir / "bin" / "leveldbtool")
  quotedArgs = quotedArgs.map(proc (x: string): string = "\"" & x & "\"")

  if not dirExists(tmpDbDir):
    createDir(tmpDbDir)

  let cmd = quotedArgs.join(" ")
  result = execCmdEx(cmd)
  checkpoint(cmd)
  checkpoint(result.output)

suite "leveldb":

  setup:
    let env = leveldb_create_default_env()
    let dbName = $(leveldb_env_get_test_directory(env))
    let db = leveldb.open(dbName)

  teardown:
    db.close()
    removeDb(dbName)

  test "version":
    let (major, minor) = getLibVersion()
    check(major > 0)
    check(minor > 0)

  test "get nothing":
    check(db.get("nothing") == none(string))

  test "put and get":
    db.put("hello", "world")
    check(db.get("hello") == some("world"))

  test "get or default":
    check(db.getOrDefault("nothing", "yes") == "yes")

  test "delete":
    db.put("hello", "world")
    db.delete("hello")
    check(db.get("hello") == none(string))

  test "get value with 0x00":
    db.put("\0key", "\0ff")
    check(db.get("\0key") == some("\0ff"))

  test "get empty value":
    db.put("a", "")
    check(db.get("a") == some(""))

  test "get empty key":
    db.put("", "a")
    check(db.get("") == some("a"))

  proc initData(db: LevelDb) =
    db.put("aa", "1")
    db.put("ba", "2")
    db.put("bb", "3")

  test "iter":
    initData(db)
    check(toSeq(db.iter()) == @[("aa", "1"), ("ba", "2"), ("bb", "3")])

  test "iter reverse":
    initData(db)
    check(toSeq(db.iter(reverse = true)) ==
          @[("bb", "3"), ("ba", "2"), ("aa", "1")])

  test "iter seek":
    initData(db)
    check(toSeq(db.iter(seek = "ab")) ==
          @[("ba", "2"), ("bb", "3")])

  test "iter seek reverse":
    initData(db)
    check(toSeq(db.iter(seek = "ab", reverse = true)) ==
          @[("ba", "2"), ("aa", "1")])

  test "iter prefix":
    initData(db)
    check(toSeq(db.iterPrefix(prefix = "b")) ==
          @[("ba", "2"), ("bb", "3")])

  test "iter range":
    initData(db)
    check(toSeq(db.iterRange(start = "a", limit = "ba")) ==
          @[("aa", "1"), ("ba", "2")])

  test "iter range reverse":
    initData(db)
    check(toSeq(db.iterRange(start = "bb", limit = "b")) ==
          @[("bb", "3"), ("ba", "2")])

  test "iter with 0x00":
    db.put("\0z1", "\0ff")
    db.put("z2\0", "ff\0")
    check(toSeq(db.iter()) == @[("\0z1", "\0ff"), ("z2\0", "ff\0")])

  test "iter empty value":
    db.put("a", "")
    check(toSeq(db.iter()) == @[("a", "")])

  test "iter empty key":
    db.put("", "a")
    check(toSeq(db.iter()) == @[("", "a")])

  test "repair database":
    initData(db)
    db.close()
    repairDb(dbName)

  test "batch":
    db.put("a", "1")
    db.put("b", "2")
    let batch = newBatch()
    batch.put("a", "10")
    batch.put("c", "30")
    batch.delete("b")
    db.write(batch)
    check(toSeq(db.iter()) == @[("a", "10"), ("c", "30")])

  test "batch append":
    let batch = newBatch()
    let batch2 = newBatch()
    batch.put("a", "1")
    batch2.put("b", "2")
    batch2.delete("a")
    batch.append(batch2)
    db.write(batch)
    check(toSeq(db.iter()) == @[("b", "2")])

  test "batch clear":
    let batch = newBatch()
    batch.put("a", "1")
    batch.clear()
    batch.put("b", "2")
    db.write(batch)
    check(toSeq(db.iter()) == @[("b", "2")])

  test "open with cache":
    let ldb = leveldb.open(dbName & "-cache", cacheCapacity = 100000)
    defer:
      ldb.close()
      removeDb(ldb.path)
    ldb.put("a", "1")
    check(toSeq(ldb.iter()) == @[("a", "1")])

  test "open but no create":
    expect LevelDbException:
      let failed = leveldb.open(dbName & "-nocreate", create = false)
      defer:
        failed.close()
        removeDb(failed.path)

  test "open but no reuse":
    let old = leveldb.open(dbName & "-noreuse", reuse = true)
    defer:
      old.close()
      removeDb(old.path)

    expect LevelDbException:
      let failed = leveldb.open(old.path, reuse = false)
      defer:
        failed.close()
        removeDb(failed.path)

  test "no compress":
    db.close()
    let nc = leveldb.open(dbName, compressionType = ctNoCompression)
    defer: nc.close()
    nc.put("a", "1")
    check(toSeq(nc.iter()) == @[("a", "1")])

suite "package":

  setup:
    removeDir(tmpDir)

  test "import as package":
    let (output, exitCode) = execNimble("install")
    check exitCode == QuitSuccess
    check output.contains("leveldb installed successfully.")

    cd "tests/packagetest":
      var (output, exitCode) = execNimble("build")
      check exitCode == QuitSuccess
      check output.contains("Building")

      (output, exitCode) = execCmdEx("./packagetest")
      checkpoint output
      check exitCode == QuitSuccess
      check output.contains("leveldb works.")

suite "tool":

  setup:
    removeDir(tmpDir)

  test "leveldb tool":
    var (output, exitCode) = execNimble("install")
    check exitCode == QuitSuccess
    check output.contains("Building")

    check execTool("-v").exitCode == QuitSuccess
    check execTool("create").exitCode == QuitSuccess
    check execTool("list").exitCode == QuitSuccess

    check execTool("put", "hello", "world").exitCode == QuitSuccess
    (output, exitCode) = execTool("get", "hello")
    check exitCode == QuitSuccess
    check output == "world\L"
    (output, exitCode) = execTool("list")
    check exitCode == QuitSuccess
    check output == "hello world\L"

    check execTool("delete", "hello").exitCode == QuitSuccess
    (output, exitCode) = execTool("get", "hello")
    check exitCode == QuitSuccess
    check output == ""
    (output, exitCode) = execTool("list")
    check exitCode == QuitSuccess
    check output == ""

    check execTool("put", "hello", "6130", "-x").exitCode == QuitSuccess
    check execTool("get", "hello", "-x").output == "6130\L"
    check execTool("get", "hello").output == "a0\L"
    check execTool("list", "-x").output == "hello 6130\L"
    check execTool("put", "hello", "0061", "-x").exitCode == QuitSuccess
    check execTool("get", "hello", "-x").output == "0061\L"
    check execTool("delete", "hello").exitCode == QuitSuccess
