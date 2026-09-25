#!/usr/bin/env python3
"""CaseFolding-<版>.txt（status C と F）から VDCore/PyCaseFoldTable.swift を作る（PLAN §5.7）。

使い方: python3 tools/unicode/gen-casefold.py tools/unicode/CaseFolding-15.0.0.txt Sources/VDCore/PyCaseFoldTable.swift
入力の sha256 を tools/unicode/CaseFolding-15.0.0.txt.sha256 と照合し、違えば止まる。
"""
import hashlib
import sys
from pathlib import Path

EXPECTED_VERSION = "15.0.0"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gen-casefold.py <CaseFolding.txt> <out.swift>", file=sys.stderr)
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    data = src.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    expected = Path(str(src) + ".sha256").read_text(encoding="ascii").split()[0]
    if digest != expected:
        print(f"sha256 が一致しません: {digest} != {expected}", file=sys.stderr)
        return 1
    text = data.decode("utf-8")
    first = text.splitlines()[0]
    if first != f"# CaseFolding-{EXPECTED_VERSION}.txt":
        print(f"版が違います: {first}", file=sys.stderr)
        return 1
    table: dict[int, list[int]] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(";")]
        code, status, mapping = fields[0], fields[1], fields[2]
        if status not in ("C", "F"):
            continue
        cp = int(code, 16)
        if cp in table:
            print(f"重複: {code}", file=sys.stderr)
            return 1
        table[cp] = [int(x, 16) for x in mapping.split()]
    lines = [
        "// 生成物。tools/unicode/gen-casefold.py が CaseFolding-"
        + EXPECTED_VERSION
        + ".txt（status C と F）から作る。手で編集しない。",
        f"// source-sha256: {digest}",
        "// 形式: 1 件ごとに「元のスカラー, 写像の長さ n, 写像のスカラー × n」を並べる（PLAN §5.7）。",
        "enum PyCaseFoldTable {",
        f"    static let unicodeVersion = \"{EXPECTED_VERSION}\"",
        f"    static let entryCount = {len(table)}",
        "    static let packed: [UInt32] = [",
    ]
    for cp in sorted(table):
        mapped = table[cp]
        body = ", ".join(f"0x{x:04X}" for x in mapped)
        lines.append(f"        0x{cp:04X}, {len(mapped)}, {body},")
    lines += [
        "    ]",
        "",
        "    static let map: [UInt32: [UInt32]] = {",
        "        var result: [UInt32: [UInt32]] = [:]",
        "        result.reserveCapacity(entryCount)",
        "        var index = 0",
        "        while index < packed.count {",
        "            let source = packed[index]",
        "            let length = Int(packed[index + 1])",
        "            result[source] = Array(packed[(index + 2)..<(index + 2 + length)])",
        "            index += 2 + length",
        "        }",
        "        return result",
        "    }()",
        "}",
        "",
    ]
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"{len(table)} 件を書きました: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
