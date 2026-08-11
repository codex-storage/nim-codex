import pkg/unittest2
import pkg/questionable

import pkg/storage/rest/api

suite "getFilenameFromContentDisposition":
  test "parse quoted filename":
    check getFilenameFromContentDisposition("attachment; filename=\"document.pdf\"") == "document.pdf".some

  test "parse quoted filename with parameters":
    check getFilenameFromContentDisposition("attachment; filename=\"report.txt\"; size=1234") == "report.txt".some

  test "parse unquoted filename":
    check getFilenameFromContentDisposition("attachment; filename=plain.txt") == "plain.txt".some

  test "parse unquoted filename with parameters":
    check getFilenameFromContentDisposition("attachment; filename=data.csv; size=500") == "data.csv".some

  test "handle empty quoted filename safely":
    check getFilenameFromContentDisposition("attachment; filename=\"\"").isNone

  test "handle malformed unclosed quote":
    check getFilenameFromContentDisposition("attachment; filename=\"unclosed").isNone

  test "handle missing filename":
    check getFilenameFromContentDisposition("attachment").isNone
    check getFilenameFromContentDisposition("").isNone
