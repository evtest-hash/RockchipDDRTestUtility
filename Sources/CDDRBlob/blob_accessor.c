#include "CDDRBlob.h"

const unsigned char *ddr_cfgs_blob_ptr(void) {
    return ddr_cfgs_blob_start;
}

size_t ddr_cfgs_blob_len(void) {
    return (size_t)(ddr_cfgs_blob_end - ddr_cfgs_blob_start);
}
