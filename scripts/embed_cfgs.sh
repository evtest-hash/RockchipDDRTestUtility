#!/usr/bin/env bash
# Regenerate the embedded DDRTestFiles blob for the single-file CLI binary.
#
# The CLI (`RockchipDDRTestUtilityCLI`) ships as ONE self-contained file so it
# can drop into an automation pipeline without a sibling DDRTestFiles/ directory.
# The whole cfg library is embedded via `.incbin` (Sources/CDDRBlob/blob.S) as an
# LZMA-compressed manifest and decompressed IN-PROCESS at runtime with Apple's
# Compression framework (libcompression) — NO external tar/zstd/unzip and no
# child process, so nothing extra is required on the target machine.
#
# Run this whenever DDRTestFiles/ changes, then `swift build -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift scripts/embed_cfgs.swift
