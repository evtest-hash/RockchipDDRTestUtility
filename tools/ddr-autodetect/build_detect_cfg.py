#!/usr/bin/env python3
"""Build a custom RK3568 "DDR detect" .cfg for RockchipDDRTestUtility.

The cfg carries two or three records the tool's existing engine already knows
how to run:
  - "Boot"      : the stock RK3568 DDR Test Tool loader (raw, downloaded via
                  control-transfer 0x471) — provides USB + 0x80 printf + the
                  service-vector table our probe calls.
  - "osregdump" : our OS_REG probe (RC4-encrypted like any test item; the tool
                  RC4-decrypts on load and sends it via bulk 0x02 to the download
                  base, then RunMemory 0x03). It reads PMU_GRF OS_REG and prints
                  the words over the 0x80 channel.
  - "reboot"    : (optional, via --reboot) writes the maskrom boot-mode magic
                  and triggers a CRU global soft-reset. Same download/run path
                  as osregdump, RC4-encrypted the same way. Does not return.

Layout mirrors a real cfg so the shipping CfgBinaryParser reads it unchanged:
  0x00      header (copied from a template RK3568 cfg)
  0x41      record[0] Boot        (marker 0x02C3, span, dataOff, UTF-16LE name)
  0x304     record[1] osregdump
  0x5B6     download base (UInt32 LE) = 0xFDCC4000 (or --download-base)
  0x5C7     record[2] reboot (only when --reboot given)
  0x88A     record[3] slot — marker zeroed so parsing stops
  0x894/0xB57  payloads: Boot, then osregdump, then (if present) reboot (RC4)

Usage:
  build_detect_cfg.py <template.cfg> <boot.bin|--from-template> <out.cfg> \\
      --probe <probe.bin> [--reboot <reboot.bin>] [--download-base <hex>]

(For backward compatibility, <probe.bin> may also be given positionally as
the 3rd argument before <out.cfg>, i.e. without --probe.)
"""
import struct, sys

RC4_KEY = bytes([0x7C,0x4E,0x03,0x04,0x55,0x05,0x09,0x07,
                 0x2D,0x2C,0x7B,0x38,0x17,0x0D,0x17,0x11])
REC0, SP = 0x41, 0x2C3
DL_BASE_OFF = 0x5B6
PAYLOAD_START = 0x894
DOWNLOAD_BASE = 0xFDCC4000

def rc4(key, data):
    s = list(range(256)); j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xff
        s[i], s[j] = s[j], s[i]
    out = bytearray(); i = j = 0
    for b in data:
        i = (i + 1) & 0xff; j = (j + s[i]) & 0xff
        s[i], s[j] = s[j], s[i]
        out.append(b ^ s[(s[i] + s[j]) & 0xff])
    return bytes(out)

def parse_records(d):
    off, recs = REC0, []
    while off + 10 < len(d):
        if (d[off] | (d[off+1] << 8)) != 0x02C3:
            break
        span = struct.unpack_from("<I", d, off+2)[0]
        doff = struct.unpack_from("<I", d, off+6)[0]
        nm = bytearray(); j = off + 10
        while j+1 < len(d) and 0x20 <= d[j] <= 0x7e and d[j+1] == 0:
            nm.append(d[j]); j += 2
        recs.append((nm.decode(), span, doff)); off += SP
    return recs

def utf16le(name):
    return b"".join(bytes([ord(c), 0]) for c in name)

def write_record(buf, idx, name, span, data_off):
    base = REC0 + idx * SP
    struct.pack_into("<H", buf, base, 0x02C3)
    struct.pack_into("<I", buf, base + 2, span)
    struct.pack_into("<I", buf, base + 6, data_off)
    nm = utf16le(name)
    buf[base+10:base+10+len(nm)] = nm
    buf[base+10+len(nm):base+12+len(nm)] = b"\x00\x00"   # terminate name

def parse_args(argv):
    """Manual argv parsing (not argparse): positional tokens like
    '--from-template' must pass through untouched even though they look like
    flags, so we only intercept the specific --flag tokens we recognize."""
    flags = {"--probe": None, "--reboot": None, "--download-base": None}
    positionals = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in flags:
            if i + 1 >= len(argv):
                raise SystemExit(f"{tok} requires a value")
            flags[tok] = argv[i + 1]
            i += 2
        else:
            positionals.append(tok)
            i += 1

    if len(positionals) == 4 and flags["--probe"] is None:
        # backward-compatible positional form: template boot_arg probe.bin out
        template, boot_arg, probe_path, out = positionals
        flags["--probe"] = probe_path
    elif len(positionals) == 3:
        template, boot_arg, out = positionals
    else:
        raise SystemExit(
            "usage: build_detect_cfg.py <template.cfg> <boot.bin|--from-template> "
            "<out.cfg> --probe <probe.bin> [--reboot <reboot.bin>] [--download-base <hex>]"
        )

    if flags["--probe"] is None:
        raise SystemExit("--probe <probe.bin> is required")

    download_base = DOWNLOAD_BASE
    if flags["--download-base"] is not None:
        download_base = int(flags["--download-base"], 0)

    return template, boot_arg, out, flags["--probe"], flags["--reboot"], download_base


def main():
    template, boot_arg, out, probe_path, reboot_path, download_base = parse_args(sys.argv[1:])
    tpl = open(template, "rb").read()

    # Boot payload: extract from template (record[0], stored raw)
    recs = parse_records(tpl)
    assert recs and recs[0][0].lower() == "boot", "template missing Boot record"
    b_span, b_off = recs[0][1], recs[0][2]
    boot = tpl[b_off:b_off + b_span] if boot_arg == "--from-template" else open(boot_arg, "rb").read()

    probe_plain = open(probe_path, "rb").read()
    probe_enc = rc4(RC4_KEY, probe_plain)   # tool RC4-decrypts on load

    reboot_plain = reboot_enc = None
    if reboot_path is not None:
        reboot_plain = open(reboot_path, "rb").read()
        reboot_enc = rc4(RC4_KEY, reboot_plain)

    boot_off = PAYLOAD_START
    probe_off = boot_off + len(boot)
    if reboot_enc is not None:
        reboot_off = probe_off + len(probe_enc)
        total = reboot_off + len(reboot_enc)
    else:
        reboot_off = None
        total = probe_off + len(probe_enc)

    buf = bytearray(tpl[:PAYLOAD_START])     # keep header; overwrite table below
    buf += bytes(total - len(buf))

    write_record(buf, 0, "Boot", len(boot), boot_off)
    write_record(buf, 1, "osregdump", len(probe_enc), probe_off)
    next_slot = 2
    if reboot_off is not None:
        write_record(buf, 2, "reboot", len(reboot_enc), reboot_off)
        next_slot = 3
    # stop parsing after the last record: clear the following record's marker
    struct.pack_into("<H", buf, REC0 + next_slot * SP, 0x0000)
    # download base
    struct.pack_into("<I", buf, DL_BASE_OFF, download_base)
    # payloads
    buf[boot_off:boot_off + len(boot)] = boot
    buf[probe_off:probe_off + len(probe_enc)] = probe_enc
    if reboot_off is not None:
        buf[reboot_off:reboot_off + len(reboot_enc)] = reboot_enc

    open(out, "wb").write(buf)
    print(f"wrote {out}: {total} bytes")
    print(f"  Boot      raw  {len(boot):6d}B @0x{boot_off:X}")
    print(f"  osregdump enc  {len(probe_enc):6d}B @0x{probe_off:X} (plain {len(probe_plain)}B)")
    if reboot_off is not None:
        print(f"  reboot    enc  {len(reboot_enc):6d}B @0x{reboot_off:X} (plain {len(reboot_plain)}B)")
    print(f"  download base = 0x{download_base:08X}")

if __name__ == "__main__":
    main()
