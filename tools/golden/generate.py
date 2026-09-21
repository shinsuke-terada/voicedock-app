#!/usr/bin/env python3
"""voicedock@d3d595e の関数で golden の期待値を作る（PLAN §10.4、T-25）。

generate.sh が `git archive` で展開した voicedock の木の中で、その木の `uv` 環境で実行する。
**voicedock の作業ツリーには触らない。**入力は Tests/Golden/inputs/*.json（make_inputs.py の出力）。

出力: Tests/Golden/expected/<group>/<case>.<ext>
  - .md / .out  … voicedock の出力文字列の UTF-8 バイト列そのもの（Swift 側はバイト列で比べる）
  - .json       … 構造化した値。json.dumps(ensure_ascii=False, indent=2) + "\\n"（Swift 側は値で比べる）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from zoneinfo import ZoneInfo

ALLOWED_OVERRIDES = {
    "obsidian.maxTitleBytes", "obsidian.defaultTags",
    "obsidian.raw.folderTemplate", "obsidian.raw.filenameTemplate",
    "obsidian.raw.timestampIntervalSeconds", "obsidian.raw.partBoundaryHeading",
    "obsidian.wiki.folderTemplate", "obsidian.wiki.filenameTemplate",
    "obsidian.wiki.linkDailyNote", "obsidian.wiki.linkAdjacentDays", "obsidian.wiki.linkTags",
    "obsidian.wiki.linkOnlyExisting", "obsidian.wiki.maxLinks",
    "llm.maxCharsPerRequest", "llm.maxSecondsPerRequest", "llm.chunkOverlapChars",
    "llm.analysis.order", "llm.analysis.customInstructions",
    "session.blockGapSeconds",
}
SECTION_OVERRIDE = re.compile(
    r"^llm\.analysis\.sections\.(summary|timeline|key_points|tasks|decisions|ideas|tags)\.(enabled|heading|maxItems)$")
# maxItems を持たない節（PLAN §6.2・付録 F の F-54。書けば CV-01）。
SECTIONS_WITHOUT_MAX_ITEMS = {"summary", "timeline"}


def is_allowed_override(key: str) -> bool:
    if key in ALLOWED_OVERRIDES:
        return True
    m = SECTION_OVERRIDE.match(key)
    if m is None:
        return False
    return not (m.group(2) == "maxItems" and m.group(1) in SECTIONS_WITHOUT_MAX_ITEMS)


def to_snake(segment: str) -> str:
    """AppConfig の JSON キー（camelCase）を voicedock の設定キー（snake_case）へ写す。"""
    return re.sub(r"(?<=[a-z0-9])([A-Z])", lambda m: "_" + m.group(1).lower(), segment)


class Generator:
    def __init__(self, voicedock_root: Path, golden: Path) -> None:
        sys.path.insert(0, str(voicedock_root))
        # voicedock のモジュールは実行時に import する（generate.sh の uv 環境にだけ在る）
        from tests import helpers  # type: ignore
        from voicedock import audio, daily, llm, notes, paths, raw, session, transcribe, wiki  # type: ignore
        self.helpers, self.audio, self.daily, self.llm = helpers, audio, daily, llm
        self.notes, self.paths, self.raw, self.session = notes, paths, raw, session
        self.transcribe, self.wiki = transcribe, wiki
        self.voicedock_root = voicedock_root
        self.golden = golden
        # 一時ファイルは展開した木の中に作る（generate.sh の trap が木ごと消す）
        self.tmp = Path(tempfile.mkdtemp(prefix="golden-", dir=voicedock_root))
        (self.tmp / "config").mkdir()
        self.base_document = helpers.complete_tree(self.tmp / "config")  # ファイル実在検査を通す設定
        self.handlers: dict[str, Callable[[dict], tuple[str, Any]]] = {
            "keys": self.keys, "sanitize": self.sanitize, "frontmatter": self.frontmatter,
            "raw_note": self.raw_note, "note_filename": self.note_filename, "daily_note": self.daily_note,
            "daily_parts": self.daily_parts, "timeline": self.timeline, "timeline_decode": self.timeline_decode,
            "wiki": self.wiki_case, "llm_schema_block": self.llm_schema_block, "llm_prompt": self.llm_prompt,
            "llm_repair_prompt": self.llm_repair_prompt, "llm_validate": self.llm_validate,
            "llm_trim": self.llm_trim, "llm_extract": self.llm_extract, "llm_strip_think": self.llm_strip_think,
            "llm_chunks": self.llm_chunks, "llm_dedupe": self.llm_dedupe, "llm_as_json": self.llm_as_json,
            "llm_bundles": self.llm_bundles, "analysis_json": self.analysis_json,
            "transcript_json": self.transcript_json, "numbers": self.numbers, "fingerprint": self.fingerprint,
            "blocks": self.blocks, "pytext": self.pytext, "pyjson": self.pyjson, "pyjson_decode": self.pyjson_decode,
            "pyround": self.pyround, "prompt_files": self.prompt_files,
        }

    # --- 共通 ------------------------------------------------------------------
    def config(self, case: dict) -> Any:
        patch: dict[str, Any] = {"timezone": case["timeZone"]}
        for key, value in case.get("overrides", {}).items():
            if not is_allowed_override(key):
                raise SystemExit(f"{case['name']}: 許可されていない上書き {key}")
            parts = [to_snake(p) for p in key.split(".")]
            cursor = patch
            for part in parts[:-1]:
                cursor = cursor.setdefault(part, {})
            cursor[parts[-1]] = value
        return self.helpers.parsed(self.helpers.merge(self.base_document, patch))

    @staticmethod
    def at(base: str, millis: int) -> datetime:
        return datetime.fromisoformat(base) + timedelta(milliseconds=millis)

    @staticmethod
    def iso(moment: datetime) -> str:
        return moment.isoformat(timespec="seconds")

    @staticmethod
    def day(case: dict) -> date:
        return date.fromisoformat(case["day"])

    def transcript(self, case: dict, payload: dict) -> Any:
        base = case["base"]
        return self.session.SessionTranscript(
            day_date=self.day(case),
            segments=[self.session.AbsoluteSegment(at=self.at(base, s["atMs"]), end_at=self.at(base, s["endMs"]),
                                                   text=s["text"]) for s in payload["segments"]],
            blocks=[(self.at(base, b["startMs"]), self.at(base, b["endMs"])) for b in payload["blocks"]],
            excluded_partkeys=[],
        )

    # --- グループごと -------------------------------------------------------------
    def keys(self, case: dict) -> tuple[str, Any]:
        if case["kind"] == "partkey":
            key = self.paths.partkey_for(case["deviceID"], PurePosixPath(case["relpath"]))
        else:
            key = self.paths.session_key_for(case["deviceID"], datetime.fromisoformat(case["startedAt"]),
                                             tz=ZoneInfo(case["timeZone"]), overflow=case["overflow"])
        return "json", {"key": str(key), "slug": self.paths.key_slug(key)}

    def sanitize(self, case: dict) -> tuple[str, Any]:
        return "out", self.notes.sanitize_filename(case["input"], max_bytes=case["maxBytes"])

    @staticmethod
    def fm_value(tagged: list) -> Any:
        kind = tagged[0]
        if kind == "s":
            return str(tagged[1])
        if kind == "i":
            return int(tagged[1])
        if kind == "b":
            return bool(tagged[1])
        if kind == "n":
            return None
        if kind == "a":
            return [str(x) for x in tagged[1]]
        raise SystemExit(f"frontmatter: 未知の型 {kind}")

    def frontmatter(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "render":
            fields = {key: self.fm_value(value) for key, value in case["fields"]}
            return "out", self.notes.render_frontmatter(fields)
        if kind == "quote":
            return "out", self.notes.yaml_quote(case["text"])
        if kind == "escapeBody":
            return "out", self.notes.escape_body(case["text"])
        if kind == "split":
            result = self.notes.split_frontmatter(case["text"])
            return "json", None if result is None else {"front": result[0], "body": result[1]}
        raise SystemExit(f"frontmatter: 未知の kind {kind}")

    def raw_note(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        parts = []
        for part in case["parts"]:
            started = datetime.fromisoformat(part["startedAt"])
            ended = datetime.fromisoformat(part["endedAt"]) if part["endedAt"] else None
            segments = tuple(self.raw.RawSegment(at=started + timedelta(milliseconds=s["startMs"]),
                                                 end_at=started + timedelta(milliseconds=s["endMs"]), text=s["text"])
                             for s in part["segments"])
            parts.append(self.raw.RawPart(part["partkey"], started, ended, segments))
        return "md", self.raw.render_raw_note(parts, day=self.day(case), session_key=case["sessionKey"],
                                              cfg=cfg.obsidian.raw)

    def note_filename(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        day = self.day(case)
        kind = case["kind"]
        if kind == "raw":
            return "out", self.raw.raw_filename(cfg.obsidian.raw, day, max_bytes=cfg.obsidian.max_title_bytes)
        if kind == "daily":
            return "out", self.daily.daily_filename(cfg, day)
        if kind == "rawFolder":
            return "out", self.raw.render_template(cfg.obsidian.raw.folder_template, day)
        if kind == "dailyFolder":
            return "out", self.raw.render_template(cfg.obsidian.wiki.folder_template, day)
        raise SystemExit(f"note_filename: 未知の kind {kind}")

    def excluded(self, items: list[dict]) -> list:
        return [self.daily.ExcludedPart(self.paths.PartKey(e["partkey"]), e["status"], e["errorCode"]) for e in items]

    def daily_note(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        analysis = self.llm.build_schema(cfg).model_validate(case["analysis"])
        tl = case["timeline"]
        blocks = [self.daily.TimelineBlock(self.at(tl["base"], b["startMs"]), self.at(tl["base"], b["endMs"]),
                                           tuple(b["lines"])) for b in tl["blocks"]]
        links = case["links"]
        plan = self.wiki.LinkPlan(daily_note=links["dailyNote"], adjacent=tuple(links["adjacent"]),
                                  tags=tuple(links["tags"]), raw=tuple(links["raw"]))
        text = self.daily.render_daily_note(
            analysis, day=self.day(case), session_key=self.paths.SessionKey(case["sessionKey"]),
            recording_keys=[self.paths.PartKey(k) for k in case["recordingKeys"]],
            excluded=self.excluded(case["excluded"]), recorded_seconds=case["recordedSeconds"],
            block_count=case["blockCount"], timeline=blocks, links=plan, cfg=cfg)
        return "md", text

    def daily_parts(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "recorded":
            return "json", [self.daily._duration(v) for v in case["inputs"]]
        if kind == "tags":
            cfg = self.config({**case, "overrides": {"obsidian.defaultTags": case["defaults"]}})
            payload: dict[str, Any] = {"title": "t", "summary": "s"}
            if case["tags"] is not None:
                payload["tags"] = case["tags"]
            analysis = self.llm.build_schema(cfg).model_validate(payload)
            return "json", self.daily._tags(analysis, cfg)
        if kind == "warnings":
            out = []
            for items in case["sets"]:
                parts = self.excluded(items)
                failed = [p for p in parts if p.status == "FAILED"]
                skipped = [p for p in parts if p.status != "FAILED"]
                out.append(self.daily._warnings(failed, skipped))
            return "json", out
        if kind == "sentences":
            return "json", [self.daily._sentences(s) for s in case["inputs"]]
        raise SystemExit(f"daily_parts: 未知の kind {kind}")

    def timeline(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        pm = self.llm.build_schema(cfg, partial=True)
        base = case["base"]
        blocks = self.daily.build_timeline(
            partials=[pm.model_validate(p) for p in case["partials"]],
            chunks=[self.llm.Chunk(text="", start_at=self.at(base, c["startMs"]), end_at=self.at(base, c["endMs"]),
                                   segments=()) for c in case["chunks"]],
            transcript=self.transcript(case, case["transcript"]), summary=case["summary"])
        work = self.tmp / "timeline" / case["name"]
        work.mkdir(parents=True, exist_ok=True)
        self.daily.save_timeline(work / "a.json", blocks, fingerprint=case["fingerprint"])
        return "out", (work / "a.timeline.json").read_text(encoding="utf-8")

    def timeline_decode(self, case: dict) -> tuple[str, Any]:
        work = self.tmp / "timeline_decode" / case["name"]
        work.mkdir(parents=True, exist_ok=True)
        (work / "a.timeline.json").write_text(case["document"], encoding="utf-8")
        blocks = self.daily.load_timeline(work / "a.json", fingerprint=case["fingerprint"])
        return "json", [{"start": self.iso(b.start_at), "end": self.iso(b.end_at), "lines": list(b.lines)}
                        for b in blocks]

    def wiki_case(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "normalize":
            return "json", [self.wiki.normalize_name(s) for s in case["inputs"]]
        cfg = self.config(case)
        if kind == "plan":
            day = self.day(case)
            names = case["indexNames"]
            index = None if names is None else self.wiki.VaultIndex(
                names=frozenset(self.wiki.normalize_name(n) for n in names), built_at=0.0)
            plan = self.wiki.plan_links(cfg=cfg, day=day, tags=case["tags"], index=index,
                                        self_name=self.daily.daily_filename(cfg, day),
                                        name_for_day=lambda d: self.daily.daily_filename(cfg, d),
                                        raw_names=case["rawNames"])
            return "json", {"dailyNote": plan.daily_note, "adjacent": list(plan.adjacent), "tags": list(plan.tags),
                            "raw": list(plan.raw), "dropped": list(plan.dropped)}
        if kind == "buildIndex":
            root = self.tmp / "vault" / case["name"]
            for rel in case["files"]:
                target = root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("", encoding="utf-8")
            for link, target in case["symlinkDirs"]:
                os.symlink(root / target, root / link)
            index = self.wiki.build_index(root, exclude_prefixes=(self.wiki.raw_folder_prefix(cfg),), now=0.0)
            return "json", sorted(index.names)
        if kind == "rawPrefix":
            return "out", self.wiki.raw_folder_prefix(cfg)
        raise SystemExit(f"wiki: 未知の kind {kind}")

    def llm_schema_block(self, case: dict) -> tuple[str, Any]:
        return "out", self.llm.render_schema_block(self.config(case), partial=case["partial"])

    def llm_prompt(self, case: dict) -> tuple[str, Any]:
        kind = self.llm.PromptKind(case["kind"])
        return "out", self.llm.system_prompt(self.config(case), kind)

    def llm_repair_prompt(self, case: dict) -> tuple[str, Any]:
        """本計画の差分（X-12）: voicedock の repair_json.txt の末尾に "\\n{schema_block}\\n" を足した雛形。"""
        cfg = self.config(case)
        original = (self.voicedock_root / "prompts" / "repair_json.txt").read_text(encoding="utf-8")
        # 前提の確認: voicedock の修復プロンプトは errors → previous_output の順の単純置換である
        expected_vd = original.replace("{errors}", case["errors"]).replace("{previous_output}", case["previousOutput"])
        actual_vd = self.llm.repair_prompt(cfg, errors=case["errors"], previous_output=case["previousOutput"])
        if expected_vd != actual_vd:
            raise SystemExit(f"{case['name']}: voicedock の修復プロンプトの前提が崩れました")
        template = original + "\n{schema_block}\n"
        block = self.llm.render_schema_block(cfg, partial=case["partial"])
        text = (template.replace("{schema_block}", block).replace("{errors}", case["errors"])
                .replace("{previous_output}", case["previousOutput"]))
        return "out", text

    def llm_validate(self, case: dict) -> tuple[str, Any]:
        from pydantic import ValidationError  # type: ignore
        model = self.llm.build_schema(self.config(case), partial=case["partial"])
        try:
            result = model.model_validate(case["payload"])
        except ValidationError as error:
            return "json", {"ok": False, "errors": self.llm._errors_of(error), "result": None}
        return "json", {"ok": True, "errors": None, "result": result.model_dump()}

    def llm_trim(self, case: dict) -> tuple[str, Any]:
        model = self.llm.build_schema(self.config(case), partial=case["partial"])
        document, trimmed = self.llm.coerce_limits(dict(case["payload"]), model)
        return "json", {"trimmed": list(trimmed), "result": document}

    def llm_extract(self, case: dict) -> tuple[str, Any]:
        return "json", self.llm.extract_json(case["text"])

    def llm_strip_think(self, case: dict) -> tuple[str, Any]:
        return "out", self.llm.strip_think(case["text"])

    def llm_chunks(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        base = datetime.fromisoformat(case["base"])
        chunks = self.llm.split_chunks(self.transcript(case, {"segments": case["segments"], "blocks": []}), cfg)
        millis = lambda moment: (moment - base) // timedelta(milliseconds=1)  # noqa: E731
        return "json", [{"texts": [s.text for s in c.segments], "startMs": millis(c.start_at),
                         "endMs": millis(c.end_at), "text": c.text} for c in chunks]

    def llm_dedupe(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "key":
            return "json", [self.llm.normalize_for_dedupe(s) for s in case["inputs"]]
        if kind == "values":
            return "json", self.llm.dedupe(case["inputs"])
        if kind == "result":
            model = self.llm.build_schema(self.config(case))
            return "json", self.llm._deduped(model.model_validate(case["payload"])).model_dump()
        raise SystemExit(f"llm_dedupe: 未知の kind {kind}")

    def llm_as_json(self, case: dict) -> tuple[str, Any]:
        pm = self.llm.build_schema(self.config(case), partial=True)
        return "out", self.llm._as_json([pm.model_validate(p) for p in case["partials"]])

    def llm_bundles(self, case: dict) -> tuple[str, Any]:
        pm = self.llm.build_schema(self.config(case), partial=True)
        items = [pm.model_validate(p) for p in case["partials"]]
        index = {id(item): i for i, item in enumerate(items)}
        return "json", [[index[id(item)] for item in bundle] for bundle in self.llm._bundles(items, case["limit"])]

    def analysis_json(self, case: dict) -> tuple[str, Any]:
        model = self.llm.build_schema(self.config(case))
        dumped = model.model_validate(case["payload"]).model_dump()
        return "out", json.dumps(dumped, ensure_ascii=False, indent=2) + "\n"

    def transcript_json(self, case: dict) -> tuple[str, Any]:
        transcript = self.transcribe.normalize(case["whisper"], partkey=self.paths.PartKey(case["partkey"]),
                                               started_at=case["startedAt"],
                                               duration_seconds=case["durationSeconds"],
                                               fallback_language=case["fallbackLanguage"])
        return "out", json.dumps(transcript.to_document(), ensure_ascii=False, indent=2) + "\n"

    def numbers(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        kind = case["kind"]
        if kind == "num":
            return "json", [self.transcribe._number(v) for v in case["inputs"]]
        if kind == "whisperTimeout":
            return "json", [self.transcribe.timeout_for(v, cfg.transcription) for v in case["inputs"]]
        if kind == "convertTimeout":
            return "json", [self.audio.convert_timeout(v, cfg) for v in case["inputs"]]
        if kind == "expectedBytes":
            return "json", [self.audio.expected_bytes(v) for v in case["inputs"]]
        raise SystemExit(f"numbers: 未知の kind {kind}")

    def fingerprint(self, case: dict) -> tuple[str, Any]:
        transcript = self.transcript(case, case)
        payload = json.dumps({
            "segments": [{"at": self.iso(s.at), "end_at": self.iso(s.end_at), "text": s.text}
                         for s in transcript.segments],
            "blocks": [[self.iso(a), self.iso(b)] for a, b in transcript.blocks],
        }, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        if digest != self.session.transcript_fingerprint(transcript):
            raise SystemExit(f"{case['name']}: 指紋の再現が voicedock と一致しません")
        return "out", payload + "\n" + digest + "\n"

    def blocks(self, case: dict) -> tuple[str, Any]:
        class Part:
            def __init__(self, started_at: str, ended_at: str | None) -> None:
                self.started_at, self.ended_at = started_at, ended_at

        base = datetime.fromisoformat(case["base"])
        parts = [Part(self.iso(base + timedelta(seconds=p["startS"])),
                      None if p["endS"] is None else self.iso(base + timedelta(seconds=p["endS"])))
                 for p in case["parts"]]
        result = self.session.compute_blocks(parts, gap_seconds=case["gapSeconds"])
        return "json", [[self.iso(a), self.iso(b)] for a, b in result]

    def pytext(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "enumerations":
            scalars = [c for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF]
            assigned = [c for c in scalars if unicodedata.category(chr(c)) != "Cn"]
            ranges: list[list[int]] = []
            for c in assigned:
                if ranges and ranges[-1][1] == c - 1:
                    ranges[-1][1] = c
                else:
                    ranges.append([c, c])
            return "json", {
                "unicodeVersion": unicodedata.unidata_version,
                "isspace": [c for c in scalars if chr(c).isspace()],
                "splitlinesSeparators": [c for c in scalars if len(("a" + chr(c) + "b").splitlines()) == 2],
                "casefold": {str(c): [ord(x) for x in chr(c).casefold()] for c in scalars
                             if chr(c).casefold() != chr(c)},
                "combining": [c for c in assigned if unicodedata.combining(chr(c)) != 0],
                "assignedRanges": ranges,
            }
        inputs = case["inputs"]
        if kind == "strip":
            return "json", [s.strip() for s in inputs]
        if kind == "stripChars":
            return "json", [s.strip(case["chars"]) for s in inputs]
        if kind == "splitlines":
            return "json", [s.splitlines() for s in inputs]
        if kind == "collapse":
            return "json", [re.sub(r"\s+", " ", s) for s in inputs]
        if kind == "casefold":
            return "json", [s.casefold() for s in inputs]
        if kind == "nfc":
            return "json", [unicodedata.normalize("NFC", s) for s in inputs]
        if kind == "nfkc":
            return "json", [unicodedata.normalize("NFKC", s) for s in inputs]
        raise SystemExit(f"pytext: 未知の kind {kind}")

    def py_value(self, tagged: list) -> Any:
        kind = tagged[0]
        if kind == "n":
            return None
        if kind == "b":
            return bool(tagged[1])
        if kind == "i":
            return int(tagged[1])
        if kind == "f":
            value = float(tagged[1])
            if repr(value) != tagged[1]:
                raise SystemExit(f"pyjson: 浮動小数の表記が repr と違います: {tagged[1]}")
            return value
        if kind == "s":
            return str(tagged[1])
        if kind == "a":
            return [self.py_value(x) for x in tagged[1]]
        if kind == "o":
            keys = [k for k, _ in tagged[1]]
            if len(keys) != len(set(keys)):
                raise SystemExit("pyjson: キーが重複しています")
            return {k: self.py_value(v) for k, v in tagged[1]}
        raise SystemExit(f"pyjson: 未知の型 {kind}")

    def pyjson(self, case: dict) -> tuple[str, Any]:
        value = self.py_value(case["value"])
        mode = case["mode"]
        if mode == "compact":
            return "out", json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        if mode == "compact_sorted":
            return "out", json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        if mode == "indent2":
            return "out", json.dumps(value, ensure_ascii=False, indent=2)
        if mode == "file":
            return "out", json.dumps(value, ensure_ascii=False, indent=2) + "\n"
        raise SystemExit(f"pyjson: 未知の mode {mode}")

    @staticmethod
    def to_tagged(value: Any) -> list:
        """json.loads の結果を型付きの配列へ（make_inputs.py の PyJSON と同じ表し方）。対にならないサロゲートは U+FFFD。"""
        if value is None:
            return ["n"]
        if isinstance(value, bool):
            return ["b", value]
        if isinstance(value, int):
            return ["i", value] if -(2 ** 63) <= value < 2 ** 63 else ["f", repr(float(value))]
        if isinstance(value, float):
            return ["f", repr(value)]
        if isinstance(value, str):
            return ["s", "".join(chr(0xFFFD) if 0xD800 <= ord(c) <= 0xDFFF else c for c in value)]
        if isinstance(value, list):
            return ["a", [Generator.to_tagged(v) for v in value]]
        if isinstance(value, dict):
            return ["o", [[k, Generator.to_tagged(v)] for k, v in value.items()]]
        raise SystemExit(f"pyjson_decode: 未知の型 {type(value)}")

    def pyjson_decode(self, case: dict) -> tuple[str, Any]:
        try:
            value = json.loads(case["text"])
        except ValueError:
            return "json", {"ok": False, "value": None}
        return "json", {"ok": True, "value": self.to_tagged(value)}

    def pyround(self, case: dict) -> tuple[str, Any]:
        return "json", [repr(round(float(s), case["digits"])) for s in case["inputs"]]

    def prompt_files(self, case: dict) -> tuple[str, Any]:
        data = (self.voicedock_root / "prompts" / f"{case['name']}.txt").read_bytes()
        return "out", data.decode("utf-8")

    # --- 実行 -------------------------------------------------------------------------
    def run(self) -> int:
        inputs = sorted((self.golden / "inputs").glob("*.json"))
        groups = {p.stem for p in inputs}
        if groups != set(self.handlers):
            raise SystemExit(f"入力と生成器のグループが一致しません: {sorted(groups ^ set(self.handlers))}")
        expected = self.golden / "expected"
        count = 0
        for path in inputs:
            document = json.loads(path.read_text(encoding="utf-8"))
            if document.get("schema") != 1 or document.get("group") != path.stem:
                raise SystemExit(f"{path.name}: schema か group が不正です")
            out_dir = expected / path.stem
            out_dir.mkdir(parents=True, exist_ok=True)
            for case in document["cases"]:
                ext, value = self.handlers[path.stem](case)
                target = out_dir / f"{case['name']}.{ext}"
                if ext == "json":
                    text = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
                else:
                    text = value
                target.write_bytes(text.encode("utf-8"))
                count += 1
        print(f"{count} 件の期待値を書きました: {expected}")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicedock-root", required=True, type=Path)
    parser.add_argument("--golden", required=True, type=Path)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--uv-version", required=True)
    args = parser.parse_args()
    generator = Generator(args.voicedock_root.resolve(), args.golden.resolve())
    status = generator.run()
    stamp = (
        f"voicedock_ref={args.ref}\n"
        f"voicedock_commit={args.commit}\n"
        f"python={sys.version.split()[0]}\n"
        f"unicodedata={unicodedata.unidata_version}\n"
        f"uv={args.uv_version}\n"
        "generator=tools/golden/generate.py\n"
    )
    (args.golden / "GENERATED_BY.txt").write_text(stamp, encoding="utf-8")
    return status


if __name__ == "__main__":
    sys.exit(main())
