#!/usr/bin/env python3
"""Imports the MIT-licensed kbsim recordings (https://github.com/tplai/kbsim, by Thomas Lai)
that ship in keyboardsounds (https://github.com/nathan-fiscaletti/keyboardsounds) into ./Packs.

kbsim records 5 alpha-key takes plus space, enter and backspace. Each take is assigned to
fixed keys spread across the board; OpenThock's deterministic fallback gives every other
key a stable sibling, so a key always plays the same take.

Usage: scripts/import-kbsim-packs.py <keyboardsounds/keyboardsounds/profiles>
"""
import json, shutil, sys
from pathlib import Path

PACKS = {
    "alpaca": ("kbsim-alpaca", "Alpaca", "Smooth linear, soft and creamy.", ["#fde68a", "#f59e0b"]),
    "gateron-black-ink": ("kbsim-black-ink", "Gateron Black Ink", "Deep, heavy linear.", ["#6b7280", "#111827"]),
    "gateron-red-ink": ("kbsim-red-ink", "Gateron Red Ink", "Light, poppy linear.", ["#fca5a5", "#b91c1c"]),
    "holy-panda": ("kbsim-holy-panda", "Holy Panda", "Famous sharp tactile bump.", ["#fde047", "#a16207"]),
    "mx-black": ("kbsim-mx-black", "Cherry MX Black (kbsim)", "Heavy linear, second recording.", ["#57534e", "#0c0a09"]),
    "mx-blue": ("kbsim-mx-blue", "Cherry MX Blue (kbsim)", "Clicky, second recording.", ["#60a5fa", "#1e40af"]),
    "mx-brown": ("kbsim-mx-brown", "Cherry MX Brown (kbsim)", "Tactile, second recording.", ["#c08457", "#5b3412"]),
}
# kbsim take → OpenThock key codes (A, S, D, F, J spread the five alpha takes).
TAKES = {"key1": [30], "key2": [32], "key3": [36], "key4": [19], "key5": [46],
         "space": [57], "enter": [28, 3612], "back": [14, 3667]}
BUNDLED_VERSION = 1


def sources(profile: Path) -> dict:
    """Minimal parse of profile.yaml's `sources:` list (id / press / release)."""
    out, cur = {}, None
    for line in profile.read_text().splitlines():
        s = line.strip()
        if s.startswith("- id:"):
            cur = s.split(":", 1)[1].strip(); out[cur] = {}
        elif cur and s.startswith(("press:", "release:")):
            k, v = s.split(":", 1); out[cur][k] = v.strip()
        elif s == "keys:":
            break
    return out


def main() -> None:
    src = Path(sys.argv[1])
    out = Path(__file__).resolve().parent.parent / "Packs"
    for folder, (slug, name, desc, colors) in PACKS.items():
        dest = out / slug
        shutil.rmtree(dest, ignore_errors=True); dest.mkdir(parents=True)
        n = 0
        for take, files in sources(src / folder / "profile.yaml").items():
            for code in TAKES.get(take, []):
                for kind, suffix in (("press", "down"), ("release", "up")):
                    if kind in files:
                        f = src / folder / files[kind]
                        shutil.copyfile(f, dest / f"{code}-{suffix}{f.suffix}"); n += 1
        shutil.copyfile(src / folder / "LICENSE", dest / "LICENSE")
        (dest / "pack.json").write_text(json.dumps({
            "name": name, "author": "Thomas Lai (kbsim)", "license": "MIT",
            "description": f"{desc} kbsim recordings.", "colors": colors, "gain": 1,
            "bundledVersion": BUNDLED_VERSION}, indent=2, sort_keys=True) + "\n")
        print(f"{name}: {n} files")


if __name__ == "__main__":
    main()
