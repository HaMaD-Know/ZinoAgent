#!/usr/bin/env python3
"""Static verification script for ZinoAgent 2.0 (runs on Windows/Linux/macOS without Xcode)."""
import json
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZINO = ROOT / "ZinoAgent"

errors = []
warnings = []


def check_plist(path: Path):
    try:
        with open(path, "rb") as f:
            plistlib.load(f)
    except Exception as e:
        errors.append(f"Invalid plist {path}: {e}")


def check_json(path: Path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            json.load(f)
    except Exception as e:
        errors.append(f"Invalid JSON {path}: {e}")


def strip_swift_strings_and_comments(code: str) -> str:
    """Rough tokenizer to strip comments and string literals before delimiter balance checks."""
    out = []
    i = 0
    n = len(code)
    while i < n:
        ch = code[i]
        nxt = code[i + 1] if i + 1 < n else ""
        # Line comment
        if ch == "/" and nxt == "/":
            while i < n and code[i] != "\n":
                i += 1
            continue
        # Block comment (nested)
        if ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if code[i:i+2] == "/*":
                    depth += 1
                    i += 2
                elif code[i:i+2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # Raw string #"..."#
        if ch == "#" and nxt == '"':
            i += 2
            while i < n:
                if code[i:i+2] == '"#':
                    i += 2
                    break
                i += 1
            continue
        # Triple-quoted string
        if code[i:i+3] == '"""':
            i += 3
            while i < n:
                if code[i:i+3] == '"""':
                    i += 3
                    break
                if code[i] == "\\":
                    i += 2
                    continue
                i += 1
            continue
        # Double-quoted string
        if ch == '"':
            i += 1
            while i < n:
                if code[i] == "\\":
                    i += 2
                    continue
                if code[i] == '"':
                    i += 1
                    break
                if code[i] == "\n":
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_swift_file(path: Path, seen_public_types: dict):
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)

    # Check delimiter balance
    cleaned = strip_swift_strings_and_comments(text)
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for ch in cleaned:
        if ch in pairs:
            stack.append(pairs[ch])
        elif ch in pairs.values():
            if not stack or stack[-1] != ch:
                errors.append(f"Unbalanced delimiter '{ch}' in {rel}")
                break
            stack.pop()
    if stack:
        errors.append(f"Unclosed delimiters {stack} in {rel}")

    # Check required framework imports
    imports = set(re.findall(r"^\s*import\s+([A-Za-z0-9_.]+)", text, re.MULTILINE))
    checks = [
        (r"\b@Published\b|\bObservableObject\b|\bAnyCancellable\b", {"Combine", "SwiftUI"}, "Combine/SwiftUI"),
        (r"\bUIImage\b|\bUIColor\b|\bUIDocumentPickerViewController\b|\bUIActivityViewController\b|\bUIPasteboard\b", {"UIKit"}, "UIKit"),
        (r"\bSCNView\b|\bSCNScene\b|\bSCNNode\b|\bSCNMaterial\b", {"SceneKit"}, "SceneKit"),
        (r"\bMDLAsset\b", {"ModelIO"}, "ModelIO"),
        (r"\bPDFDocument\b|\bPDFView\b", {"PDFKit"}, "PDFKit"),
        (r"\bSecItemAdd\b|\bSecItemCopyMatching\b", {"Security"}, "Security"),
        (r"\bsqlite3_open_v2\b", {"SQLite3"}, "SQLite3"),
        (r"\bNLEmbedding\b", {"NaturalLanguage"}, "NaturalLanguage"),
        (r"\bPHPhotoLibrary\b", {"Photos"}, "Photos"),
        (r"\bPhotosPicker\b", {"PhotosUI"}, "PhotosUI"),
        (r"\bBGTaskScheduler\b", {"BackgroundTasks"}, "BackgroundTasks"),
        (r"\bUTType\b", {"UniformTypeIdentifiers"}, "UniformTypeIdentifiers"),
    ]
    for pattern, required_any, label in checks:
        if re.search(pattern, cleaned) and not (imports & required_any):
            errors.append(f"Missing import ({label}) in {rel}")

    # Check duplicate top-level public types
    for m in re.finditer(r"^(?:@MainActor\s+)?(?:public\s+)(?:final\s+)?(class|struct|enum|protocol)\s+([A-Za-z0-9_]+)", text, re.MULTILINE):
        type_name = m.group(2)
        if type_name in seen_public_types:
            errors.append(f"Duplicate public type '{type_name}' in {rel} and {seen_public_types[type_name]}")
        else:
            seen_public_types[type_name] = str(rel)

    # Check for forbidden stubs / placeholders
    for marker in ["TODO:", "FIXME:", "fatalError(\"Not implemented", "placeholder"]:
        if marker.lower() in text.lower() and "Tests" not in str(rel):
            warnings.append(f"Found marker '{marker}' in {rel}")


def main():
    # 1. Plist & entitlements
    for p in ROOT.rglob("*.plist"):
        check_plist(p)
    for p in ROOT.rglob("*.entitlements"):
        check_plist(p)

    # 2. JSON files
    for p in ROOT.rglob("*.json"):
        if ".git" in p.parts:
            continue
        check_json(p)

    # 3. Swift files
    swift_files = sorted(ZINO.rglob("*.swift"))
    seen_public_types = {}
    for sf in swift_files:
        check_swift_file(sf, seen_public_types)

    # 4. Check project.yml source paths exist
    proj_yml = (ROOT / "project.yml").read_text(encoding="utf-8")
    for m in re.finditer(r"^\s*-\s*path:\s*(.+)$", proj_yml, re.MULTILINE):
        p = ROOT / m.group(1).strip()
        if not p.exists():
            errors.append(f"project.yml references missing path: {m.group(1).strip()}")

    # 5. Check YAML parses if PyYAML installed
    try:
        import yaml  # type: ignore
        yaml.safe_load(proj_yml)
        yaml.safe_load((ROOT / ".github/workflows/ios-build.yml").read_text(encoding="utf-8"))
    except ImportError:
        pass
    except Exception as e:
        errors.append(f"YAML syntax error: {e}")

    print(f"Scanned {len(swift_files)} Swift source files ({len(seen_public_types)} public types).")
    if warnings:
        print(f"Warnings ({len(warnings)}):")
        for w in warnings:
            print(f"  [WARN] {w}")
    if errors:
        print(f"Errors ({len(errors)}):")
        for e in errors:
            print(f"  [ERR]  {e}")
        sys.exit(1)
    print("ALL STATIC CHECKS PASSED.")


if __name__ == "__main__":
    main()
