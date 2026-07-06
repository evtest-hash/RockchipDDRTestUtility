#!/usr/bin/env bash
# Assemble the probe + reboot payloads for RK3568 and regenerate the detect cfg.
# Run this after editing probe.S.in / reboot.S.in / build_detect_cfg.py.
set -euo pipefail
cd "$(dirname "$0")"

DL=0xFDCC4000; PUTS=0xFDCC1004; OSREG=0xFDC20200
BMR=0xFDC20200; MAGIC=0xEF08A53C; CRUR=0xFDD200D4; CRUV=0x0000FDB9
TPL="../../DDRTestFiles/RK3568&RK3566/8GB LPDDR4X(用4个CS且每个CS为16Gb组成)焊接检测.cfg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# NOTE: clang only auto-preprocesses assembly files named *.S (uppercase);
# our *.S.in templates need -x assembler-with-cpp so the -D symbols
# (USB_PUTS, OSREG_BASE, ...) are substituted before assembly.
clang --target=aarch64-linux-gnu -x assembler-with-cpp -ffreestanding -nostdlib \
  -DUSB_PUTS=$PUTS -DOSREG_BASE=$OSREG -c probe.S.in -o "$TMP/probe.o"
python3 extract_text.py "$TMP/probe.o" probe.bin

clang --target=aarch64-linux-gnu -x assembler-with-cpp -ffreestanding -nostdlib \
  -DBOOT_MODE_REG=$BMR -DMASKROM_MAGIC=$MAGIC -DCRU_RESET_REG=$CRUR -DCRU_RESET_VAL=$CRUV \
  -c reboot.S.in -o "$TMP/reboot.o"
python3 extract_text.py "$TMP/reboot.o" reboot.bin

python3 build_detect_cfg.py "$TPL" --from-template rk3568_osregdump.cfg \
  --probe probe.bin --reboot reboot.bin --download-base $DL
