#!/usr/bin/env python3
"""Converts the per-key Mechvibes recordings published by KeyClick
(https://github.com/MohAlkurdi/keyclick, MIT; recordings by Hai Nguyen / Mechvibes, MIT)
into OpenThock packs under ./Packs.

Usage: scripts/import-keyclick-packs.py <path to extracted keyclick repo>
"""
import json
import shutil
import sys
from pathlib import Path

# W3C KeyboardEvent.code → libuiohook code (OpenThock / Klack file naming).
CODES = {
    "Escape": 1, "Backquote": 41, "Minus": 12, "Equal": 13, "Backspace": 14, "Tab": 15,
    "BracketLeft": 26, "BracketRight": 27, "Backslash": 43, "CapsLock": 58,
    "Semicolon": 39, "Quote": 40, "Enter": 28, "ShiftLeft": 42, "ShiftRight": 54,
    "Comma": 51, "Period": 52, "Slash": 53, "ControlLeft": 29, "ControlRight": 3613,
    "AltLeft": 56, "AltRight": 3640, "MetaLeft": 3675, "MetaRight": 3676, "Space": 57,
    "ArrowUp": 57416, "ArrowLeft": 57419, "ArrowRight": 57421, "ArrowDown": 57424,
    "Home": 3655, "End": 3663, "PageUp": 3657, "PageDown": 3665, "Delete": 3667, "Insert": 3666,
    "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64, "F7": 65, "F8": 66,
    "F9": 67, "F10": 68, "F11": 87, "F12": 88,
}
CODES.update({f"Digit{d}": (11 if d == 0 else d + 1) for d in range(10)})
LETTERS = {
    "Q": 16, "W": 17, "E": 18, "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23, "O": 24, "P": 25,
    "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35, "J": 36, "K": 37, "L": 38,
    "Z": 44, "X": 45, "C": 46, "V": 47, "B": 48, "N": 49, "M": 50,
}
CODES.update({f"Key{k}": v for k, v in LETTERS.items()})

PACKS = {
    "MX Black": ("mechvibes-mx-black", "Cherry MX Black", "Heavy linear.", ["#78716c", "#1c1917"]),
    "MX Red": ("mechvibes-mx-red", "Cherry MX Red", "Light linear.", ["#fca5a5", "#dc2626"]),
    "MX Brown": ("mechvibes-mx-brown", "Cherry MX Brown", "Tactile bump.", ["#d6a77a", "#7c4a1e"]),
    "MX Blue": ("mechvibes-mx-blue", "Cherry MX Blue", "Clicky.", ["#93c5fd", "#2563eb"]),
    "Topre": ("mechvibes-topre", "Topre", "Electro-capacitive rubber dome, the deep 'thock'.", ["#e7e5e4", "#57534e"]),
}
BUNDLED_VERSION = 1


def main() -> None:
    src = Path(sys.argv[1]) / "Sounds"
    out = Path(__file__).resolve().parent.parent / "Packs"
    out.mkdir(exist_ok=True)
    for folder, (slug, name, desc, colors) in PACKS.items():
        dest = out / slug
        shutil.rmtree(dest, ignore_errors=True)
        dest.mkdir()
        count = 0
        for direction, suffix in (("press", "down"), ("release", "up")):
            for wav in sorted((src / folder / direction).glob("*.wav")):
                code = CODES.get(wav.stem)
                if code is None:
                    print(f"  skip unknown key {wav.stem}")
                    continue
                shutil.copyfile(wav, dest / f"{code}-{suffix}.wav")
                count += 1
        manifest = {
            "name": name,
            "author": "Hai Nguyen (Mechvibes); sliced per key by KeyClick",
            "license": "MIT",
            "description": f"{desc} Real per-key recordings from Mechvibes.",
            "colors": colors,
            "gain": 1,
            "bundledVersion": BUNDLED_VERSION,
        }
        (dest / "pack.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"{name}: {count} files → {dest.relative_to(out.parent)}")


if __name__ == "__main__":
    main()
