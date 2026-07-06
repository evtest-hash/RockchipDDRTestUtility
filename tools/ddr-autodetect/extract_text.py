#!/usr/bin/env python3
"""Extract the raw .text bytes from an AArch64 ELF relocatable (.o).
No objcopy dependency — parses the ELF section headers directly.
Usage: extract_text.py <in.o> <out.bin>
"""
import struct, sys

def extract_text(path):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 2, "not ELF64"
    # ELF64 header: e_shoff@0x28 (8), e_shentsize@0x3a (2), e_shnum@0x3c (2), e_shstrndx@0x3e (2)
    e_shoff = struct.unpack_from("<Q", d, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", d, 0x3a)[0]
    e_shnum = struct.unpack_from("<H", d, 0x3c)[0]
    e_shstrndx = struct.unpack_from("<H", d, 0x3e)[0]
    def sh(i):
        b = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size = struct.unpack_from("<IIQQQQ", d, b)
        return name, off, size
    strtab_off = sh(e_shstrndx)[1]
    def nm(n):
        e = d.index(b"\x00", strtab_off + n)
        return d[strtab_off + n:e].decode()
    for i in range(e_shnum):
        name, off, size = sh(i)
        if nm(name) == ".text":
            return d[off:off + size]
    raise SystemExit(".text not found")

if __name__ == "__main__":
    out = extract_text(sys.argv[1])
    open(sys.argv[2], "wb").write(out)
    print(f"wrote {sys.argv[2]}: {len(out)} bytes")
