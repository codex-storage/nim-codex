import pkg/unittest2
import pkg/libp2p/cid

import pkg/storage/blocktype
import pkg/storage/blockexchange/protocol/message

## All Expected_* consts were generated from the minprotobuf encoder and are
## the current wire format.
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY
## DO NOT MODIFY any of the Expected_* consts. If tests are failing after
## touching message.nim, the protobuf library, the custom Cid encoder or anything
## else in the encode path, the wire format has diverged from what
## existing peers expect and they will not be able to decode any messages.

const Expected_emptyMessage = @[0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8]

const Expected_wantListEmptyFullFalse = @[0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8]

const Expected_wantListEmptyFullTrue = @[0x0A'u8, 0x02'u8, 0x10'u8, 0x01'u8]

const Expected_wantListSingleEntry = @[
  0x0A'u8, 0x3A'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x05'u8, 0x10'u8, 0x01'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x01'u8,
  0x30'u8, 0x00'u8, 0x38'u8, 0x2A'u8, 0x10'u8, 0x00'u8,
]

const Expected_wantListMultipleFullTrue = @[
  0x0A'u8, 0x72'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x00'u8, 0x10'u8, 0x0A'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x00'u8,
  0x30'u8, 0x05'u8, 0x38'u8, 0x01'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xBB'u8, 0x10'u8, 0x64'u8, 0x10'u8, 0x32'u8, 0x18'u8, 0x01'u8, 0x20'u8, 0x00'u8,
  0x28'u8, 0x01'u8, 0x30'u8, 0x0A'u8, 0x38'u8, 0x02'u8, 0x10'u8, 0x01'u8,
]

const Expected_presenceDontHave = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x2E'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0x07'u8, 0x10'u8, 0x00'u8, 0x20'u8, 0x64'u8,
]

const Expected_presenceHaveRange = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x3B'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xBB'u8, 0x10'u8, 0x00'u8, 0x10'u8, 0x01'u8, 0x1A'u8, 0x04'u8, 0x08'u8, 0x00'u8,
  0x10'u8, 0x0A'u8, 0x1A'u8, 0x04'u8, 0x08'u8, 0x64'u8, 0x10'u8, 0x32'u8, 0x20'u8,
  0xF4'u8, 0x03'u8,
]

const Expected_presenceComplete = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x30'u8, 0x0A'u8, 0x29'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0xE7'u8, 0x07'u8, 0x10'u8, 0x02'u8, 0x20'u8, 0x8F'u8, 0x4E'u8,
]

const Expected_fullMessage = @[
  0x0A'u8, 0x3A'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x01'u8, 0x10'u8, 0x05'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x00'u8,
  0x30'u8, 0x02'u8, 0x38'u8, 0x01'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x34'u8, 0x0A'u8,
  0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8,
  0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8,
  0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8,
  0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8,
  0x1D'u8, 0x1E'u8, 0xBB'u8, 0x10'u8, 0x0A'u8, 0x10'u8, 0x01'u8, 0x1A'u8, 0x04'u8,
  0x08'u8, 0x05'u8, 0x10'u8, 0x03'u8, 0x20'u8, 0x01'u8, 0x22'u8, 0x2E'u8, 0x0A'u8,
  0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8,
  0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8,
  0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8,
  0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8,
  0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8, 0x14'u8, 0x10'u8, 0x02'u8, 0x20'u8, 0x01'u8,
]

const Expected_largeVarints = @[
  0x0A'u8, 0x55'u8, 0x0A'u8, 0x51'u8, 0x0A'u8, 0x2D'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0x1F'u8, 0x10'u8, 0xFF'u8, 0xFF'u8,
  0xFF'u8, 0xFF'u8, 0x07'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x00'u8,
  0x30'u8, 0xEF'u8, 0xFD'u8, 0xB6'u8, 0xF5'u8, 0xED'u8, 0xD7'u8, 0xAE'u8, 0xFF'u8,
  0xCA'u8, 0x01'u8, 0x38'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
  0xFF'u8, 0xFF'u8, 0xFF'u8, 0x01'u8, 0x10'u8, 0x00'u8,
]

const Expected_allZeroValues = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x34'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0x00'u8, 0x10'u8, 0x00'u8, 0x1A'u8, 0x04'u8, 0x08'u8, 0x00'u8,
  0x10'u8, 0x00'u8, 0x20'u8, 0x00'u8,
]

const Expected_wantListFullTrueWithPresences = @[
  0x0A'u8, 0x3A'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x03'u8, 0x10'u8, 0x07'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x01'u8,
  0x30'u8, 0x04'u8, 0x38'u8, 0x0B'u8, 0x10'u8, 0x01'u8, 0x22'u8, 0x34'u8, 0x0A'u8,
  0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8,
  0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8,
  0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8,
  0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8,
  0x1D'u8, 0x1E'u8, 0xBB'u8, 0x10'u8, 0x04'u8, 0x10'u8, 0x01'u8, 0x1A'u8, 0x04'u8,
  0x08'u8, 0x00'u8, 0x10'u8, 0x10'u8, 0x20'u8, 0x0B'u8,
]

const Expected_threeBlockPresences = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x34'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0x01'u8, 0x10'u8, 0x01'u8, 0x1A'u8, 0x04'u8, 0x08'u8, 0x00'u8,
  0x10'u8, 0x08'u8, 0x20'u8, 0x15'u8, 0x22'u8, 0x2E'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xBB'u8, 0x10'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x20'u8, 0x16'u8, 0x22'u8, 0x2E'u8,
  0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8,
  0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8,
  0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8,
  0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8,
  0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8, 0x03'u8, 0x10'u8, 0x02'u8, 0x20'u8,
  0x17'u8,
]

const Expected_multipleEntriesCancelTrue = @[
  0x0A'u8, 0x72'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x01'u8, 0x10'u8, 0x01'u8, 0x18'u8, 0x01'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x00'u8,
  0x30'u8, 0x01'u8, 0x38'u8, 0x1F'u8, 0x0A'u8, 0x36'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xBB'u8, 0x10'u8, 0x02'u8, 0x10'u8, 0x02'u8, 0x18'u8, 0x01'u8, 0x20'u8, 0x00'u8,
  0x28'u8, 0x00'u8, 0x30'u8, 0x01'u8, 0x38'u8, 0x20'u8, 0x10'u8, 0x00'u8,
]

const Expected_presenceDownloadIdMax = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x37'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0x01'u8, 0x10'u8, 0x00'u8, 0x20'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
  0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0x01'u8,
]

const Expected_entryRangeCountMax = @[
  0x0A'u8, 0x43'u8, 0x0A'u8, 0x3F'u8, 0x0A'u8, 0x28'u8, 0x0A'u8, 0x24'u8, 0x01'u8,
  0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8, 0x04'u8, 0x05'u8,
  0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8, 0x0D'u8, 0x0E'u8,
  0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8, 0x16'u8, 0x17'u8,
  0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8, 0xAA'u8, 0x10'u8,
  0x01'u8, 0x10'u8, 0x01'u8, 0x18'u8, 0x00'u8, 0x20'u8, 0x00'u8, 0x28'u8, 0x00'u8,
  0x30'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8,
  0xFF'u8, 0x01'u8, 0x38'u8, 0x01'u8, 0x10'u8, 0x00'u8,
]

const Expected_rangeStartNearMax = @[
  0x0A'u8, 0x02'u8, 0x10'u8, 0x00'u8, 0x22'u8, 0x3D'u8, 0x0A'u8, 0x28'u8, 0x0A'u8,
  0x24'u8, 0x01'u8, 0x55'u8, 0x12'u8, 0x20'u8, 0x00'u8, 0x01'u8, 0x02'u8, 0x03'u8,
  0x04'u8, 0x05'u8, 0x06'u8, 0x07'u8, 0x08'u8, 0x09'u8, 0x0A'u8, 0x0B'u8, 0x0C'u8,
  0x0D'u8, 0x0E'u8, 0x0F'u8, 0x10'u8, 0x11'u8, 0x12'u8, 0x13'u8, 0x14'u8, 0x15'u8,
  0x16'u8, 0x17'u8, 0x18'u8, 0x19'u8, 0x1A'u8, 0x1B'u8, 0x1C'u8, 0x1D'u8, 0x1E'u8,
  0xAA'u8, 0x10'u8, 0x00'u8, 0x10'u8, 0x01'u8, 0x1A'u8, 0x0D'u8, 0x08'u8, 0xFE'u8,
  0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8, 0x01'u8,
  0x10'u8, 0x01'u8, 0x20'u8, 0x29'u8,
]

## Deterministic Cids for stable byte fixtures.
## CIDv1, raw codec (0x55), sha2-256 (0x12, 0x20) + 32 fixed bytes.
proc fixedCid(seed: byte): Cid =
  var bytes = @[
    0x01.byte, 0x55, 0x12, 0x20, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
    0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
  ]
  bytes[^1] = seed
  Cid.init(bytes).expect("valid Cid bytes")

let cidA = fixedCid(0xAA)
let cidB = fixedCid(0xBB)

suite "Block exchange Message wire-format contract":
  test "Should encode an empty Message":
    let msg = Message()
    check msg.protobufEncode() == Expected_emptyMessage

  test "Should encode a WantList with no entries":
    let msg1 = Message(wantList: WantList(entries: @[], full: false))
    check msg1.protobufEncode() == Expected_wantListEmptyFullFalse

    let msg2 = Message(wantList: WantList(entries: @[], full: true))
    check msg2.protobufEncode() == Expected_wantListEmptyFullTrue

  test "Should encode a WantList containing a single entry":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 5),
            priority: 1,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: true,
            rangeCount: 0,
            downloadId: 42,
          )
        ]
      )
    )
    check msg.protobufEncode() == Expected_wantListSingleEntry

  test "Should encode a WantList containing multiple entries":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 0),
            priority: 10,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 5,
            downloadId: 1,
          ),
          WantListEntry(
            address: BlockAddress(treeCid: cidB, index: 100),
            priority: 50,
            cancel: true,
            wantType: WantType.WantHave,
            sendDontHave: true,
            rangeCount: 10,
            downloadId: 2,
          ),
        ],
        full: true,
      )
    )
    check msg.protobufEncode() == Expected_wantListMultipleFullTrue

  test "Should encode a BlockPresence with DontHave kind":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 7),
          kind: BlockPresenceType.DontHave,
          ranges: @[],
          downloadId: 100,
        )
      ]
    )
    check msg.protobufEncode() == Expected_presenceDontHave

  test "Should encode a BlockPresence with HaveRange kind and multiple ranges":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidB, index: 0),
          kind: BlockPresenceType.HaveRange,
          ranges:
            @[Range(start: 0'u64, count: 10'u64), Range(start: 100'u64, count: 50'u64)],
          downloadId: 500,
        )
      ]
    )
    check msg.protobufEncode() == Expected_presenceHaveRange

  test "Should encode a BlockPresence with Complete kind":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 999),
          kind: BlockPresenceType.Complete,
          ranges: @[],
          downloadId: 9999,
        )
      ]
    )
    check msg.protobufEncode() == Expected_presenceComplete

  test "Should encode a Message combining WantList and multiple BlockPresences":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 1),
            priority: 5,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 2,
            downloadId: 1,
          )
        ],
        full: false,
      ),
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidB, index: 10),
          kind: BlockPresenceType.HaveRange,
          ranges: @[Range(start: 5'u64, count: 3'u64)],
          downloadId: 1,
        ),
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 20),
          kind: BlockPresenceType.Complete,
          ranges: @[],
          downloadId: 1,
        ),
      ],
    )
    check msg.protobufEncode() == Expected_fullMessage

  test "Should encode a Message with maximum-width varint values":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 0xFFFFFFFFFF'u64),
            priority: int32(0x7FFFFFFF),
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 0xCAFEBABE_DEADBEEF'u64,
            downloadId: 0xFFFFFFFFFFFFFFFF'u64,
          )
        ]
      )
    )
    check msg.protobufEncode() == Expected_largeVarints

  test "Should encode a Message with all-zero default values":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 0),
          kind: BlockPresenceType.DontHave,
          ranges: @[Range(start: 0'u64, count: 0'u64)],
          downloadId: 0,
        )
      ]
    )
    check msg.protobufEncode() == Expected_allZeroValues

  test "Should round-trip every captured byte fixture (decode + re-encode)":
    let fixtures = @[
      ("emptyMessage", Expected_emptyMessage),
      ("wantListEmptyFullFalse", Expected_wantListEmptyFullFalse),
      ("wantListEmptyFullTrue", Expected_wantListEmptyFullTrue),
      ("wantListSingleEntry", Expected_wantListSingleEntry),
      ("wantListMultipleFullTrue", Expected_wantListMultipleFullTrue),
      ("presenceDontHave", Expected_presenceDontHave),
      ("presenceHaveRange", Expected_presenceHaveRange),
      ("presenceComplete", Expected_presenceComplete),
      ("fullMessage", Expected_fullMessage),
      ("largeVarints", Expected_largeVarints),
      ("allZeroValues", Expected_allZeroValues),
      ("wantListFullTrueWithPresences", Expected_wantListFullTrueWithPresences),
      ("threeBlockPresences", Expected_threeBlockPresences),
      ("multipleEntriesCancelTrue", Expected_multipleEntriesCancelTrue),
      ("presenceDownloadIdMax", Expected_presenceDownloadIdMax),
      ("entryRangeCountMax", Expected_entryRangeCountMax),
      ("rangeStartNearMax", Expected_rangeStartNearMax),
    ]
    for (name, expected) in fixtures:
      checkpoint("fixture: " & name)
      let decoded = Message.protobufDecode(expected)
      check decoded.isOk
      check decoded.get.protobufEncode() == expected

  test "Should encode a WantList combined with BlockPresences":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 3),
            priority: 7,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: true,
            rangeCount: 4,
            downloadId: 11,
          )
        ],
        full: true,
      ),
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidB, index: 4),
          kind: BlockPresenceType.HaveRange,
          ranges: @[Range(start: 0'u64, count: 16'u64)],
          downloadId: 11,
        )
      ],
    )
    check msg.protobufEncode() == Expected_wantListFullTrueWithPresences

  test "Should encode a Message containing three BlockPresences":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 1),
          kind: BlockPresenceType.HaveRange,
          ranges: @[Range(start: 0'u64, count: 8'u64)],
          downloadId: 21,
        ),
        BlockPresence(
          address: BlockAddress(treeCid: cidB, index: 2),
          kind: BlockPresenceType.DontHave,
          ranges: @[],
          downloadId: 22,
        ),
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 3),
          kind: BlockPresenceType.Complete,
          ranges: @[],
          downloadId: 23,
        ),
      ]
    )
    check msg.protobufEncode() == Expected_threeBlockPresences

  test "Should encode a WantList where multiple entries have cancel=true":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 1),
            priority: 1,
            cancel: true,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 1,
            downloadId: 31,
          ),
          WantListEntry(
            address: BlockAddress(treeCid: cidB, index: 2),
            priority: 2,
            cancel: true,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 1,
            downloadId: 32,
          ),
        ],
        full: false,
      )
    )
    check msg.protobufEncode() == Expected_multipleEntriesCancelTrue

  test "Should encode a BlockPresence with downloadId at uint64 maximum":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 1),
          kind: BlockPresenceType.DontHave,
          ranges: @[],
          downloadId: 0xFFFFFFFFFFFFFFFF'u64,
        )
      ]
    )
    check msg.protobufEncode() == Expected_presenceDownloadIdMax

  test "Should encode a WantListEntry with rangeCount at uint64 maximum":
    let msg = Message(
      wantList: WantList(
        entries: @[
          WantListEntry(
            address: BlockAddress(treeCid: cidA, index: 1),
            priority: 1,
            cancel: false,
            wantType: WantType.WantHave,
            sendDontHave: false,
            rangeCount: 0xFFFFFFFFFFFFFFFF'u64,
            downloadId: 1,
          )
        ]
      )
    )
    check msg.protobufEncode() == Expected_entryRangeCountMax

  test "Should encode a Range with start near uint64 maximum and count=1":
    let msg = Message(
      blockPresences: @[
        BlockPresence(
          address: BlockAddress(treeCid: cidA, index: 0),
          kind: BlockPresenceType.HaveRange,
          ranges: @[Range(start: 0xFFFFFFFFFFFFFFFE'u64, count: 1'u64)],
          downloadId: 41,
        )
      ]
    )
    check msg.protobufEncode() == Expected_rangeStartNearMax

suite "Block exchange Message decode error handling":
  test "Should reject empty bytes":
    let decoded = Message.protobufDecode(@[])
    check decoded.isErr

  test "Should reject random garbage bytes":
    let garbage = @[
      0xFF.byte, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
      0xFF, 0xFF, 0xFF,
    ]
    let decoded = Message.protobufDecode(garbage)
    check decoded.isErr

  test "Should reject truncated bytes":
    let truncated = Expected_fullMessage[0 ..< 8]
    let decoded = Message.protobufDecode(@truncated)
    check decoded.isErr

  test "Should reject bytes with a length-prefix exceeding buffer":
    # Tag 0x0A = field 1, length-delimited. Length 0xFF claims 255 bytes but
    # only 2 follow.
    let malformed = @[0x0A.byte, 0xFF, 0x00, 0x00]
    let decoded = Message.protobufDecode(malformed)
    check decoded.isErr

  test "Should reject bytes with an unknown wire type":
    # Tag 0x0F = field 1, wire type 7 (reserved/invalid).
    let malformed = @[0x0F.byte, 0x00]
    let decoded = Message.protobufDecode(malformed)
    check decoded.isErr

  test "Should not crash on a varint with continuation bits set indefinitely":
    # 10 bytes with continuation bit set — exceeds varint max length.
    let malformed =
      @[0x08.byte, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    let decoded = Message.protobufDecode(malformed)
    check decoded.isErr

  test "Should reject a Message containing an invalid Cid":
    var corrupted = @Expected_presenceDontHave
    for i in 10 .. 45:
      corrupted[i] = 0xCC
    let decoded = Message.protobufDecode(corrupted)
    check decoded.isErr

# ============================================================================
# For reference: minprotobuf encoders that produced the Expected_* bytes above.
# Kept as documentation of the wire-format derivation.
# ============================================================================

when false:
  import pkg/libp2p/protobuf/minprotobuf

  proc write*(pb: var ProtoBuffer, field: int, value: BlockAddress) =
    var ipb = initProtoBuffer()
    ipb.write(1, value.treeCid.data.buffer)
    ipb.write(2, value.index.uint64)
    ipb.finish()
    pb.write(field, ipb)

  proc write*(pb: var ProtoBuffer, field: int, value: WantListEntry) =
    var ipb = initProtoBuffer()
    ipb.write(1, value.address)
    ipb.write(2, value.priority.uint64)
    ipb.write(3, value.cancel.uint)
    ipb.write(4, value.wantType.uint)
    ipb.write(5, value.sendDontHave.uint)
    ipb.write(6, value.rangeCount)
    ipb.write(7, value.downloadId)
    ipb.finish()
    pb.write(field, ipb)

  proc write*(pb: var ProtoBuffer, field: int, value: WantList) =
    var ipb = initProtoBuffer()
    for v in value.entries:
      ipb.write(1, v)
    ipb.write(2, value.full.uint)
    ipb.finish()
    pb.write(field, ipb)

  proc write*(pb: var ProtoBuffer, field: int, value: BlockPresence) =
    var ipb = initProtoBuffer()
    ipb.write(1, value.address)
    ipb.write(2, value.kind.uint)
    for r in value.ranges:
      var rangePb = initProtoBuffer()
      rangePb.write(1, r.start)
      rangePb.write(2, r.count)
      rangePb.finish()
      ipb.write(3, rangePb)
    ipb.write(4, value.downloadId)
    ipb.finish()
    pb.write(field, ipb)

  proc protobufEncode*(value: Message): seq[byte] =
    var ipb = initProtoBuffer()
    ipb.write(1, value.wantList)
    for v in value.blockPresences:
      ipb.write(4, v)
    ipb.finish()
    ipb.buffer
