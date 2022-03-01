type
  LeopardResult* {.pure.} = enum
    Leopard_CallInitialize = -7.cint
    Leopard_Platform       = -6.cint
    Leopard_InvalidInput   = -5.cint
    Leopard_InvalidCounts  = -4.cint
    Leopard_InvalidSize    = -3.cint
    Leopard_TooMuchData    = -2.cint
    Leopard_NeedMoreData   = -1.cint
    Leopard_Success        =  0.cint

const
  header = "leopard.h"

{.pragma: leo, cdecl, header: header.}

proc leo_init*(): cint {.leo, importCpp.}

func leo_result_string*(res: LeopardResult): cstring {.leo, importc.}

func leo_encode_work_count*(original_count, recovery_count: cuint): cuint
  {.leo, importc.}

proc leo_encode*(buffer_bytes: uint64, original_count, recovery_count,
  work_count: cuint, original_data, work_data: pointer): LeopardResult
  {.leo, importc.}

func leo_decode_work_count*(original_count, recovery_count: cuint): cuint
  {.leo, importc.}

proc leo_decode*(buffer_bytes: uint64, original_count, recovery_count,
  work_count: cuint, original_data, recovery_data, work_data: pointer):
  LeopardResult {.leo, importc.}
