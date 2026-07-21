// Embeds the LZMA-compressed cfg-library blob directly into the binary's
// __DATA,__const section via .incbin. Regenerate the blob with
// `bash scripts/embed_cfgs.sh`. The path is relative to the package root
// (SwiftPM's working directory when assembling this target).
.global _ddr_cfgs_blob_start
.global _ddr_cfgs_blob_end
.section __DATA,__const
.p2align 4
_ddr_cfgs_blob_start:
.incbin "Sources/CDDRBlob/ddr_cfgs.blob"
_ddr_cfgs_blob_end:
