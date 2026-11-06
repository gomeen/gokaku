#pragma once
// miniz 3.0.2, inflate-only integration. See miniz-LICENSE.txt.
#define MINIZ_NO_ARCHIVE_APIS
#define MINIZ_NO_DEFLATE_APIS
#define MINIZ_NO_ZLIB_APIS
#define MINIZ_NO_STDIO
#define MINIZ_NO_TIME
#define MINIZ_LITTLE_ENDIAN 1
#define MINIZ_USE_UNALIGNED_LOADS_AND_STORES 0
#define MINIZ_HAS_64BIT_REGISTERS 1
#include "miniz_common.h"
#include "miniz_tinfl.h"
