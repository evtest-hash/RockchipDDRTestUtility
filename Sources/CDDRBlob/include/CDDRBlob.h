#ifndef CDDRBLOB_H
#define CDDRBLOB_H

#include <stddef.h>

// Bounds of the embedded LZMA-compressed cfg-library blob (see blob.S).
// The blob layout is: [u64 LE uncompressedSize][LZMA stream]; decode it
// in-process with Apple's Compression framework (EmbeddedCfgs.swift).
extern const unsigned char ddr_cfgs_blob_start[];
extern const unsigned char ddr_cfgs_blob_end[];

// Swift-friendly accessors (an unsized `extern` array does not import cleanly
// as a pointer, so expose it through functions).
const unsigned char *ddr_cfgs_blob_ptr(void);
size_t ddr_cfgs_blob_len(void);

#endif /* CDDRBLOB_H */
