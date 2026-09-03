#!/usr/bin/env python3
"""Scramble a Discogs token for Config/Secrets.xcconfig.

    ./Scripts/obfuscate-token.py <token> [bundle-identifier]

Prints the line to paste into Config/Secrets.xcconfig, which is gitignored.
Keep the raw token in a password manager: this is obfuscation, not encryption,
and anyone with the app can reverse it. Its purpose is to keep the credential
out of `strings`, `plutil` output and screen-shares — not to make it secret.

Must stay in step with ObfuscatedSecret.swift; ObfuscatedSecretTests pins them.
"""
import base64
import sys

SALT = bytes([
    0x49, 0x6e, 0x64, 0x69, 0x67, 0x6f, 0x2d, 0x44,
    0x49, 0x47, 0x2d, 0x32, 0x30, 0x32, 0x36, 0x5f,
])


def conceal(value: str, bundle_id: str) -> str:
    plain = value.encode("utf-8")
    ident = bundle_id.encode("utf-8")
    key = bytes(
        (SALT[i % len(SALT)] + (ident[i % len(ident)] * 3)) & 0xFF
        for i in range(len(plain))
    )
    scrambled = bytes(a ^ b for a, b in zip(plain, key))
    # URL-safe alphabet, so the blob can never contain "/". Standard base64 can
    # produce "//" by chance, and "//" opens a comment in xcconfig — which
    # silently truncates the value and ships a broken half-token.
    return base64.urlsafe_b64encode(scrambled).decode()


if __name__ == "__main__":
    if not 2 <= len(sys.argv) <= 3:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    token = sys.argv[1]
    bundle = sys.argv[2] if len(sys.argv) == 3 else "com.oblaststudio.Indigo"
    print(f"DISCOGS_TOKEN_OBFUSCATED = {conceal(token, bundle)}")
