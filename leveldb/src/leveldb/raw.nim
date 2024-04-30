##  Copyright (c) 2011 The LevelDB Authors. All rights reserved.
##   Use of this source code is governed by a BSD-style license that can be
##   found in the LICENSE file. See the AUTHORS file for names of contributors.
##
##   C bindings for leveldb.  May be useful as a stable ABI that can be
##   used by programs that keep leveldb in a shared library, or for
##   a JNI api.
##
##   Does not support:
##   . getters for the option types
##   . custom comparators that implement key shortening
##   . custom iter, db, env, cache implementations using just the C bindings
##
##   Some conventions:
##
##   (1) We expose just opaque struct pointers and functions to clients.
##   This allows us to change internal representations without having to
##   recompile clients.
##
##   (2) For simplicity, there is no equivalent to the Slice type.  Instead,
##   the caller has to pass the pointer and length as separate
##   arguments.
##
##   (3) Errors are represented by a null-terminated c string.  NULL
##   means no error.  All operations that can raise an error are passed
##   a "char** errptr" as the last argument.  One of the following must
##   be true on entry:
## errptr == NULL
## errptr points to a malloc()ed null-terminated error message
##        (On Windows, \*errptr must have been malloc()-ed by this library.)
##   On success, a leveldb routine leaves \*errptr unchanged.
##   On failure, leveldb frees the old value of \*errptr and
##   set \*errptr to a malloc()ed error message.
##
##   (4) Bools have the type uint8_t (0 == false; rest == true)
##
##   (5) All of the pointer arguments must be non-NULL.
##

{.passl: "-lleveldb".}

## # Exported types

type
  leveldb_options_t* = object
  leveldb_writeoptions_t* = object
  leveldb_readoptions_t* = object
  leveldb_writebatch_t* = object
  leveldb_iterator_t* = object
  leveldb_snapshot_t* = object
  leveldb_comparator_t* = object
  leveldb_filterpolicy_t* = object
  leveldb_env_t* = object
  leveldb_logger_t* = object
  leveldb_cache_t* = object
  leveldb_t* = object

##  DB operations

proc leveldb_open*(options: ptr leveldb_options_t; name: cstring; errptr: ptr cstring): ptr leveldb_t {.importc.}
proc leveldb_close*(db: ptr leveldb_t) {.importc.}
proc leveldb_put*(db: ptr leveldb_t; options: ptr leveldb_writeoptions_t; key: cstring;
                 keylen: csize_t; val: cstring; vallen: csize_t; errptr: ptr cstring) {.importc.}
proc leveldb_delete*(db: ptr leveldb_t; options: ptr leveldb_writeoptions_t;
                    key: cstring; keylen: csize_t; errptr: ptr cstring) {.importc.}
proc leveldb_write*(db: ptr leveldb_t; options: ptr leveldb_writeoptions_t;
                   batch: ptr leveldb_writebatch_t; errptr: ptr cstring) {.importc.}
##  Returns NULL if not found.  A malloc()ed array otherwise.
##    Stores the length of the array in \*vallen.

proc leveldb_get*(db: ptr leveldb_t; options: ptr leveldb_readoptions_t; key: cstring;
                 keylen: csize_t; vallen: ptr csize_t; errptr: ptr cstring): cstring {.importc.}
proc leveldb_create_iterator*(db: ptr leveldb_t; options: ptr leveldb_readoptions_t): ptr leveldb_iterator_t {.importc.}
proc leveldb_create_snapshot*(db: ptr leveldb_t): ptr leveldb_snapshot_t {.importc.}
proc leveldb_release_snapshot*(db: ptr leveldb_t; snapshot: ptr leveldb_snapshot_t) {.importc.}
##  Returns NULL if property name is unknown.
##    Else returns a pointer to a malloc()-ed null-terminated value.

proc leveldb_property_value*(db: ptr leveldb_t; propname: cstring): cstring {.importc.}
proc leveldb_approximate_sizes*(db: ptr leveldb_t; num_ranges: cint;
                               range_start_key: ptr cstring;
                               range_start_key_len: ptr csize_t;
                               range_limit_key: ptr cstring;
                               range_limit_key_len: ptr csize_t; sizes: ptr uint64) {.importc.}
proc leveldb_compact_range*(db: ptr leveldb_t; start_key: cstring;
                           start_key_len: csize_t; limit_key: cstring;
                           limit_key_len: csize_t) {.importc.}
##  Management operations

proc leveldb_destroy_db*(options: ptr leveldb_options_t; name: cstring;
                        errptr: ptr cstring) {.importc.}
proc leveldb_repair_db*(options: ptr leveldb_options_t; name: cstring;
                       errptr: ptr cstring) {.importc.}
##  Iterator

proc leveldb_iter_destroy*(a1: ptr leveldb_iterator_t) {.importc.}
proc leveldb_iter_valid*(a1: ptr leveldb_iterator_t): uint8 {.importc.}
proc leveldb_iter_seek_to_first*(a1: ptr leveldb_iterator_t) {.importc.}
proc leveldb_iter_seek_to_last*(a1: ptr leveldb_iterator_t) {.importc.}
proc leveldb_iter_seek*(a1: ptr leveldb_iterator_t; k: cstring; klen: csize_t) {.importc.}
proc leveldb_iter_next*(a1: ptr leveldb_iterator_t) {.importc.}
proc leveldb_iter_prev*(a1: ptr leveldb_iterator_t) {.importc.}
proc leveldb_iter_key*(a1: ptr leveldb_iterator_t; klen: ptr csize_t): cstring {.importc.}
proc leveldb_iter_value*(a1: ptr leveldb_iterator_t; vlen: ptr csize_t): cstring {.importc.}
proc leveldb_iter_get_error*(a1: ptr leveldb_iterator_t; errptr: ptr cstring) {.importc.}
##  Write batch

proc leveldb_writebatch_create*(): ptr leveldb_writebatch_t {.importc.}
proc leveldb_writebatch_destroy*(a1: ptr leveldb_writebatch_t) {.importc.}
proc leveldb_writebatch_clear*(a1: ptr leveldb_writebatch_t) {.importc.}
proc leveldb_writebatch_put*(a1: ptr leveldb_writebatch_t; key: cstring; klen: csize_t;
                            val: cstring; vlen: csize_t) {.importc.}
proc leveldb_writebatch_delete*(a1: ptr leveldb_writebatch_t; key: cstring;
                               klen: csize_t) {.importc.}
proc leveldb_writebatch_iterate*(a1: ptr leveldb_writebatch_t; state: pointer; put: proc (
    a1: pointer; k: cstring; klen: csize_t; v: cstring; vlen: csize_t); deleted: proc (
    a1: pointer; k: cstring; klen: csize_t)) {.importc.}
proc leveldb_writebatch_append*(destination: ptr leveldb_writebatch_t;
                               source: ptr leveldb_writebatch_t) {.importc.}
##  Options

proc leveldb_options_create*(): ptr leveldb_options_t {.importc.}
proc leveldb_options_destroy*(a1: ptr leveldb_options_t) {.importc.}
proc leveldb_options_set_comparator*(a1: ptr leveldb_options_t;
                                    a2: ptr leveldb_comparator_t) {.importc.}
proc leveldb_options_set_filter_policy*(a1: ptr leveldb_options_t;
                                       a2: ptr leveldb_filterpolicy_t) {.importc.}
proc leveldb_options_set_create_if_missing*(a1: ptr leveldb_options_t; a2: uint8) {.importc.}
proc leveldb_options_set_error_if_exists*(a1: ptr leveldb_options_t; a2: uint8) {.importc.}
proc leveldb_options_set_paranoid_checks*(a1: ptr leveldb_options_t; a2: uint8) {.importc.}
proc leveldb_options_set_env*(a1: ptr leveldb_options_t; a2: ptr leveldb_env_t) {.importc.}
proc leveldb_options_set_info_log*(a1: ptr leveldb_options_t;
                                  a2: ptr leveldb_logger_t) {.importc.}
proc leveldb_options_set_write_buffer_size*(a1: ptr leveldb_options_t; a2: csize_t) {.importc.}
proc leveldb_options_set_max_open_files*(a1: ptr leveldb_options_t; a2: cint) {.importc.}
proc leveldb_options_set_cache*(a1: ptr leveldb_options_t; a2: ptr leveldb_cache_t) {.importc.}
proc leveldb_options_set_block_size*(a1: ptr leveldb_options_t; a2: csize_t) {.importc.}
proc leveldb_options_set_block_restart_interval*(a1: ptr leveldb_options_t; a2: cint) {.importc.}
proc leveldb_options_set_max_file_size*(a1: ptr leveldb_options_t; a2: csize_t) {.importc.}
const
  leveldb_no_compression* = 0
  leveldb_snappy_compression* = 1

proc leveldb_options_set_compression*(a1: ptr leveldb_options_t; a2: cint) {.importc.}
##  Comparator

proc leveldb_comparator_create*(state: pointer; destructor: proc (a1: pointer); compare: proc (
    a1: pointer; a: cstring; alen: csize_t; b: cstring; blen: csize_t): cint;
                               name: proc (a1: pointer): cstring): ptr leveldb_comparator_t {.importc.}
proc leveldb_comparator_destroy*(a1: ptr leveldb_comparator_t) {.importc.}
##  Filter policy

proc leveldb_filterpolicy_create*(state: pointer; destructor: proc (a1: pointer);
    create_filter: proc (a1: pointer; key_array: ptr cstring;
                       key_length_array: ptr csize_t; num_keys: cint;
                       filter_length: ptr csize_t): cstring; key_may_match: proc (
    a1: pointer; key: cstring; length: csize_t; filter: cstring; filter_length: csize_t): uint8;
                                 name: proc (a1: pointer): cstring): ptr leveldb_filterpolicy_t {.importc.}
proc leveldb_filterpolicy_destroy*(a1: ptr leveldb_filterpolicy_t) {.importc.}
proc leveldb_filterpolicy_create_bloom*(bits_per_key: cint): ptr leveldb_filterpolicy_t {.importc.}
##  Read options

proc leveldb_readoptions_create*(): ptr leveldb_readoptions_t {.importc.}
proc leveldb_readoptions_destroy*(a1: ptr leveldb_readoptions_t) {.importc.}
proc leveldb_readoptions_set_verify_checksums*(a1: ptr leveldb_readoptions_t;
    a2: uint8) {.importc.}
proc leveldb_readoptions_set_fill_cache*(a1: ptr leveldb_readoptions_t; a2: uint8) {.importc.}
proc leveldb_readoptions_set_snapshot*(a1: ptr leveldb_readoptions_t;
                                      a2: ptr leveldb_snapshot_t) {.importc.}
##  Write options

proc leveldb_writeoptions_create*(): ptr leveldb_writeoptions_t {.importc.}
proc leveldb_writeoptions_destroy*(a1: ptr leveldb_writeoptions_t) {.importc.}
proc leveldb_writeoptions_set_sync*(a1: ptr leveldb_writeoptions_t; a2: uint8) {.importc.}
##  Cache

proc leveldb_cache_create_lru*(capacity: csize_t): ptr leveldb_cache_t {.importc.}
proc leveldb_cache_destroy*(cache: ptr leveldb_cache_t) {.importc.}
##  Env

proc leveldb_create_default_env*(): ptr leveldb_env_t {.importc.}
proc leveldb_env_destroy*(a1: ptr leveldb_env_t) {.importc.}
##  If not NULL, the returned buffer must be released using leveldb_free().

proc leveldb_env_get_test_directory*(a1: ptr leveldb_env_t): cstring {.importc.}
##  Utility
##  Calls free(ptr).
##    REQUIRES: ptr was malloc()-ed and returned by one of the routines
##    in this file.  Note that in certain cases (typically on Windows), you
##    may need to call this routine instead of free(ptr) to dispose of
##    malloc()-ed memory returned by this library.

proc leveldb_free*(`ptr`: pointer) {.importc.}
##  Return the major version number for this release.

proc leveldb_major_version*(): cint {.importc.}
##  Return the minor version number for this release.

proc leveldb_minor_version*(): cint {.importc.}
