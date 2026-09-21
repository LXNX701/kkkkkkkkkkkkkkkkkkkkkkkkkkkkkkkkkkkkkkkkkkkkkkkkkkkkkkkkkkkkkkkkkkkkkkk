#!/usr/bin/env python3
import argparse
import hashlib
import os
import struct
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

MAGIC = b"PVLT3105"
VERSION = 1
ENTRY_SIZE = 32 + 8 + 8


def c_array(name: str, data: bytes) -> str:
    values = ", ".join(f"0x{b:02x}" for b in data)
    return f"static volatile const uint8_t {name}[32] = {{ {values} }};"


def build(input_dir: Path, vault_out: Path, bridge_out: Path) -> None:
    files = sorted(p for p in input_dir.glob("*.3105") if p.is_file())
    if not files:
        raise SystemExit(f"no .3105 files found in {input_dir}")

    key = os.urandom(32)
    share_a = os.urandom(32)
    share_b = os.urandom(32)
    share_c = bytes(k ^ a ^ b for k, a, b in zip(key, share_a, share_b))
    aead = ChaCha20Poly1305(key)

    encrypted = []
    for path in files:
        # Treat patch payloads as opaque bytes. No parsing or format inspection.
        raw = path.read_bytes()
        name_hash = hashlib.sha256(path.name.encode("utf-8")).digest()
        nonce = os.urandom(12)
        sealed = nonce + aead.encrypt(nonce, raw, name_hash)
        encrypted.append((name_hash, sealed))

    header_size = len(MAGIC) + 4 + 4 + ENTRY_SIZE * len(encrypted)
    offset = header_size
    table = bytearray()
    payload = bytearray()
    for name_hash, sealed in encrypted:
        table += name_hash
        table += struct.pack("<Q", offset)
        table += struct.pack("<Q", len(sealed))
        payload += sealed
        offset += len(sealed)

    vault = MAGIC + struct.pack("<II", VERSION, len(encrypted)) + table + payload
    vault_out.parent.mkdir(parents=True, exist_ok=True)
    vault_out.write_bytes(vault)

    bridge = f'''#include "PatchVaultBridge.h"\n#include <mach-o/getsect.h>\n#include <mach-o/ldsyms.h>\n#include <stdint.h>\n#include <stddef.h>\n\n{c_array("pv_share_a", share_a)}\n{c_array("pv_share_b", share_b)}\n{c_array("pv_share_c", share_c)}\n\nconst uint8_t *patch_vault_section(size_t *size) {{\n    if (size) *size = 0;\n    unsigned long section_size = 0;\n    const struct mach_header_64 *header = (const struct mach_header_64 *)&_mh_execute_header;\n    const uint8_t *bytes = getsectiondata(header, "__DATA", "__pv3105", &section_size);\n    if (!bytes || section_size == 0) return NULL;\n    if (size) *size = (size_t)section_size;\n    return bytes;\n}}\n\n__attribute__((noinline))\nvoid patch_vault_copy_key(uint8_t out_key[32]) {{\n    if (!out_key) return;\n    for (size_t i = 0; i < 32; i++) {{\n        out_key[i] = (uint8_t)(pv_share_a[i] ^ pv_share_b[i] ^ pv_share_c[i]);\n    }}\n}}\n'''
    bridge_out.parent.mkdir(parents=True, exist_ok=True)
    bridge_out.write_text(bridge, encoding="utf-8")

    print(f"vault entries: {len(encrypted)}")
    print(f"vault bytes: {len(vault)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--vault", required=True, type=Path)
    parser.add_argument("--bridge", required=True, type=Path)
    args = parser.parse_args()
    build(args.input, args.vault, args.bridge)


if __name__ == "__main__":
    main()
