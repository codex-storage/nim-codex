##
##     Copyright (c) 2017 Christopher A. Taylor.  All rights reserved.
##
##     Redistribution and use in source and binary forms, with or without
##     modification, are permitted provided that the following conditions are met:
##
##  Redistributions of source code must retain the above copyright notice,
##       this list of conditions and the following disclaimer.
##  Redistributions in binary form must reproduce the above copyright notice,
##       this list of conditions and the following disclaimer in the documentation
##       and/or other materials provided with the distribution.
##  Neither the name of Leopard-RS nor the names of its contributors may be
##       used to endorse or promote products derived from this software without
##       specific prior written permission.
##
##     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
##     AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
##     IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
##     ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
##     LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
##     CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
##     SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
##     INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
##     CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
##     ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
##     POSSIBILITY OF SUCH DAMAGE.
##

##
##     Leopard-RS
##     MDS Reed-Solomon Erasure Correction Codes for Large Data in C
##
##     Algorithms are described in LeopardCommon.h
##
##
##     Inspired by discussion with:
##
##     Sian-Jhen Lin <sjhenglin@gmail.com> : Author of {1} {3}, basis for Leopard
##     Bulat Ziganshin <bulat.ziganshin@gmail.com> : Author of FastECC
##     Yutaka Sawada <tenfon@outlook.jp> : Author of MultiPar
##
##
##     References:
##
##     {1} S.-J. Lin, T. Y. Al-Naffouri, Y. S. Han, and W.-H. Chung,
##     "Novel Polynomial Basis with Fast Fourier Transform
##     and Its Application to Reed-Solomon Erasure Codes"
##     IEEE Trans. on Information Theory, pp. 6284-6299, November, 2016.
##
##     {2} D. G. Cantor, "On arithmetical algorithms over finite fields",
##     Journal of Combinatorial Theory, Series A, vol. 50, no. 2, pp. 285-300, 1989.
##
##     {3} Sian-Jheng Lin, Wei-Ho Chung, "An Efficient (n, k) Information
##     Dispersal Algorithm for High Code Rate System over Fermat Fields,"
##     IEEE Commun. Lett., vol.16, no.12, pp. 2036-2039, Dec. 2012.
##
##     {4} Plank, J. S., Greenan, K. M., Miller, E. L., "Screaming fast Galois Field
##     arithmetic using Intel SIMD instructions."  In: FAST-2013: 11th Usenix
##     Conference on File and Storage Technologies, San Jose, 2013
##

## ------------------------------------------------------------------------------
##  Initialization API
##
##     leo_init()
##
##     Perform static initialization for the library, verifying that the platform
##     is supported.
##
##     Returns 0 on success and other values on failure.
##

const
  header = "leopard.h"

{.pragma: leo, cdecl, header: header.}

proc leoInit*(): cint {.leo, importcpp: "leo_init".}

## ------------------------------------------------------------------------------
##  Shared Constants / Datatypes
##  Results

type
  LeopardResult* = enum
    LeopardCallInitialize = -7, ##  Call leo_init() first
    LeopardPlatform = -6,       ##  Platform is unsupported
    LeopardInvalidInput = -5,   ##  A function parameter was invalid
    LeopardInvalidCounts = -4,  ##  Invalid counts provided
    LeopardInvalidSize = -3,    ##  Buffer size must be a multiple of 64 bytes
    LeopardTooMuchData = -2,    ##  Buffer counts are too high
    LeopardNeedMoreData = -1,   ##  Not enough recovery data received
    LeopardSuccess = 0          ##  Operation succeeded


##  Convert Leopard result to string

proc leoResultString*(result: LeopardResult): cstring {.leo, importc: "leo_result_string".}
## ------------------------------------------------------------------------------
##  Encoder API
##
##     leo_encode_work_count()
##
##     Calculate the number of work_data buffers to provide to leo_encode().
##
##     The sum of original_count + recovery_count must not exceed 65536.
##
##     Returns the work_count value to pass into leo_encode().
##     Returns 0 on invalid input.
##

proc leoEncodeWorkCount*(originalCount: cuint; recoveryCount: cuint): cuint {.
    leo, importc: "leo_encode_work_count".}
##
##     leo_encode()
##
##     Generate recovery data.
##
##     original_count: Number of original_data[] buffers provided.
##     recovery_count: Number of desired recovery data buffers.
##     buffer_bytes:   Number of bytes in each data buffer.
##     original_data:  Array of pointers to original data buffers.
##     work_count:     Number of work_data[] buffers, from leo_encode_work_count().
##     work_data:      Array of pointers to work data buffers.
##
##     The sum of original_count + recovery_count must not exceed 65536.
##     The recovery_count <= original_count.
##
##     The buffer_bytes must be a multiple of 64.
##     Each buffer should have the same number of bytes.
##     Even the last piece must be rounded up to the block size.
##
##     Let buffer_bytes = The number of bytes in each buffer:
##
##         original_count = static_cast<unsigned>(
##             ((uint64_t)total_bytes + buffer_bytes - 1) / buffer_bytes);
##
##     Or if the number of pieces is known:
##
##         buffer_bytes = static_cast<unsigned>(
##             ((uint64_t)total_bytes + original_count - 1) / original_count);
##
##     Returns Leopard_Success on success.
##  The first set of recovery_count buffers in work_data will be the result.
##     Returns other values on errors.
##

proc leoEncode*(bufferBytes: uint64; originalCount: cuint; recoveryCount: cuint;
               workCount: cuint; originalData: ptr pointer; workData: ptr pointer): LeopardResult {.
    leo, importc: "leo_encode".}
  ##  Number of bytes in each data buffer
  ##  Number of original_data[] buffer pointers
  ##  Number of recovery_data[] buffer pointers
  ##  Number of work_data[] buffer pointers, from leo_encode_work_count()
  ##  Array of pointers to original data buffers
##  Array of work buffers
## ------------------------------------------------------------------------------
##  Decoder API
##
##     leo_decode_work_count()
##
##     Calculate the number of work_data buffers to provide to leo_decode().
##
##     The sum of original_count + recovery_count must not exceed 65536.
##
##     Returns the work_count value to pass into leo_encode().
##     Returns 0 on invalid input.
##

proc leoDecodeWorkCount*(originalCount: cuint; recoveryCount: cuint): cuint {.
    leo, importc: "leo_decode_work_count".}
##
##     leo_decode()
##
##     Decode original data from recovery data.
##
##     buffer_bytes:   Number of bytes in each data buffer.
##     original_count: Number of original_data[] buffers provided.
##     original_data:  Array of pointers to original data buffers.
##     recovery_count: Number of recovery_data[] buffers provided.
##     recovery_data:  Array of pointers to recovery data buffers.
##     work_count:     Number of work_data[] buffers, from leo_decode_work_count().
##     work_data:      Array of pointers to recovery data buffers.
##
##     Lost original/recovery data should be set to NULL.
##
##     The sum of recovery_count + the number of non-NULL original data must be at
##     least original_count in order to perform recovery.
##
##     Returns Leopard_Success on success.
##     Returns other values on errors.
##

proc leoDecode*(bufferBytes: uint64; originalCount: cuint; recoveryCount: cuint;
               workCount: cuint; originalData: ptr pointer;
               recoveryData: ptr pointer; workData: ptr pointer): LeopardResult {.
    leo, importc: "leo_decode".}
  ##  Number of bytes in each data buffer
  ##  Number of original_data[] buffer pointers
  ##  Number of recovery_data[] buffer pointers
  ##  Number of buffer pointers in work_data[]
  ##  Array of original data buffers
  ##  Array of recovery data buffers
##  Array of work data buffers
