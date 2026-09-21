#!/usr/bin/env python3
"""golden の入力 fixture（Tests/Golden/inputs/*.json）を作る（PLAN §10.4、T-25）。

**ケースの定義はこのファイルだけに書く。**inputs/*.json はこのファイルの出力であり、手で編集しない。
Swift のテストは inputs/*.json を読み、generate.py は inputs/*.json を読んで voicedock の関数で期待値を作る。

使い方: python3 tools/golden/make_inputs.py <Tests/Golden>
"""
from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path

SCHEMA = 1
TZ = "Asia/Tokyo"
DAY = "2026-08-29"
SK = "DJIMIC3:20260829"
KA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
KB = "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
BASE = "2026-08-29T07:12:04+09:00"


def seg(start_ms: int, end_ms: int, text: str) -> dict:
    """Part の started_at からのミリ秒で表した 1 区間（Raw ノート用）。"""
    return {"startMs": start_ms, "endMs": end_ms, "text": text}


def aseg(at_ms: int, end_ms: int, text: str) -> dict:
    """ケースの base からのミリ秒で表した絶対区間（統合結果・チャンク・指紋用）。"""
    return {"atMs": at_ms, "endMs": end_ms, "text": text}


def span(start_ms: int, end_ms: int) -> dict:
    return {"startMs": start_ms, "endMs": end_ms}


# --- keys --------------------------------------------------------------------
KEYS = [
    {"name": "partkey_fixed", "kind": "partkey", "deviceID": "DJIMIC3",
     "relpath": "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"},
    {"name": "partkey_no_name", "kind": "partkey", "deviceID": "NO NAME",
     "relpath": "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"},
    {"name": "partkey_root_file", "kind": "partkey", "deviceID": "DJIMIC3",
     "relpath": "TX01_MIC001_20260829_071204_orig.wav"},
    {"name": "session_fixed", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T07:12:04+09:00", "overflow": 1},
    {"name": "session_overflow2", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T07:12:04+09:00", "overflow": 2},
    {"name": "session_utc_input_converted", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-28T23:50:00+00:00", "overflow": 1},
    {"name": "session_late_night", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T23:50:00+09:00", "overflow": 1},
]

# --- sanitize ----------------------------------------------------------------
SANITIZE = [
    ("plain", "2026-08-29 raw", 180), ("colon", "{date}:raw", 180), ("slash_spaces", "  a / b  ", 180),
    ("dots_around", "..hidden..", 180), ("dots_inside", "a.b.c", 180), ("reserved_con", "con", 180),
    ("reserved_com1", "Com1", 180), ("reserved_lpt9_dot", "LPT9.", 180), ("reserved_nul_space", "NUL ", 180),
    ("console_not_reserved", "CONSOLE", 180), ("com10_not_reserved", "COM10", 180),
    ("hash_caret_brackets", "a#b^c[d]e", 180), ("wikilink", "[[Note]]", 180), ("tab_del", "tab\there\x7f", 180),
    ("empty", "", 180), ("spaces_only", "   ", 180), ("dots_only", "...", 180), ("hashes_only", "###", 180),
    ("controls_only", "\x00\x01", 180), ("brackets_only", "[[]]", 180), ("nfd_to_nfc", "か\U00003099", 180),
    ("combining_tail", "q\U00000301", 180), ("japanese_70", "あ" * 70, 180), ("japanese_80", "あ" * 80, 180),
    ("ascii_180_bytes", "a" * 178 + "é", 180), ("ascii_181_bytes", "a" * 179 + "é", 180),
    ("fullwidth_spaces", "x\U00003000\U00003000y", 180), ("forbidden_chars", "a|b<c>d*e?f\"g\\h", 180),
    ("nbsp_zwsp", "a\U000000a0b\U0000200bc", 180), ("e_acute_100", "é" * 100, 180), ("ga_5_max7", "が" * 5, 7),
    ("ga_5_max4", "が" * 5, 4), ("con_max3", "CON", 3), ("c1_nel", "a\U00000085b", 180), ("fs_x1c", "a\x1cb", 180),
    ("line_separator", "a\U00002028b", 180), ("tabs_inside", "a\t\tb", 180), ("spaces_inside", "  a   b  ", 180),
]

# --- frontmatter -------------------------------------------------------------
# 値は型付きの配列で表す: ["s", 文字列] / ["i", 整数] / ["b", 真偽] / ["n"] / ["a", [文字列…]]
FRONTMATTER = [
    {"name": "all_types", "kind": "render", "fields": [
        ["s", ["s", "text"]], ["i", ["i", 3]], ["b", ["b", True]], ["f", ["b", False]], ["n", ["n"]],
        ["e", ["a", []]], ["l", ["a", ["x", "y\""]]]]},
    {"name": "special_chars", "kind": "render", "fields": [
        ["s", ["s", "a\"b\\c\x01d\x7fe\U00000085f\U00002028g"]], ["colon", ["s", "a: b #c"]],
        ["jp", ["s", "日本語"]], ["empty", ["s", ""]]]},
    {"name": "raw_like", "kind": "render", "fields": [
        ["type", ["s", "voice-raw"]], ["voicedock_session_key", ["s", SK]],
        ["voicedock_recording_keys", ["a", [KA, KB]]], ["date", ["s", DAY]], ["parts", ["i", 2]],
        ["source", ["s", "DJI Mic 3"]]]},
    {"name": "quote_plain", "kind": "quote", "text": "abc"},
    {"name": "quote_escapes", "kind": "quote", "text": "a\"b\\c\x00\x1f\x7f\U00000085"},
    {"name": "escape_lines", "kind": "escapeBody", "text": "---\na\n --- \n----x\n"},
    {"name": "escape_crlf", "kind": "escapeBody", "text": "a\r\n---\r\nx\r---\n"},
    {"name": "escape_none", "kind": "escapeBody", "text": "no dashes here\n"},
    {"name": "split_ok", "kind": "split", "text": "---\na: 1\n---   \nbody\n"},
    {"name": "split_no_frontmatter", "kind": "split", "text": "a: 1\n---\n"},
    {"name": "split_unclosed", "kind": "split", "text": "---\na: 1\n"},
    {"name": "split_empty_front", "kind": "split", "text": "---\n---\nbody"},
]

# --- raw_note ----------------------------------------------------------------
PA = {"partkey": KA, "startedAt": "2026-08-29T07:12:04+09:00", "endedAt": "2026-08-29T07:42:04+09:00",
      "segments": [seg(0, 10000, "おはようございます。"),
                   seg(300000, 310000, "削除条件を整理します。")]}
PB = {"partkey": KB, "startedAt": "2026-08-29T07:42:10+09:00", "endedAt": "2026-08-29T08:12:10+09:00",
      "segments": [seg(0, 10000, "続きです。")]}
RAW_NOTE = [
    {"name": "two_parts_reordered", "overrides": {}, "parts": [PB, PA]},
    {"name": "no_end", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:12:04+09:00", "endedAt": None, "segments": [
            seg(0, 10000, "  x  "), seg(56000, 60000, "   "), seg(60000, 70000, "---"),
            seg(359000, 360000, "y"), seg(360000, 361000, "z")]}]},
    {"name": "no_headings", "overrides": {"obsidian.raw.timestampIntervalSeconds": 0,
                                          "obsidian.raw.partBoundaryHeading": False}, "parts": [PA, PB]},
    {"name": "empty", "overrides": {}, "parts": []},
    {"name": "part_without_text", "overrides": {}, "parts": [
        PA, {"partkey": KB, "startedAt": "2026-08-29T07:42:10+09:00", "endedAt": "2026-08-29T08:12:10+09:00",
             "segments": [seg(0, 10000, "   ")]}]},
    {"name": "two_minute_segments", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:20:00+09:00",
         "segments": [seg(i * 120000, i * 120000 + 5000, f"発話{i}") for i in range(10)]}]},
    {"name": "boundary_exactly_300s", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:30:00+09:00",
         "segments": [seg(0, 1000, "a"), seg(299999, 300000, "b"), seg(300000, 301000, "c"),
                      seg(599999, 600000, "d"), seg(600001, 601000, "e")]}]},
    {"name": "subsecond_heading_truncated", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:10:00+09:00",
         "segments": [seg(999, 2000, "a"), seg(301999, 302500, "b")]}]},
    {"name": "dst_fixed_offset", "timeZone": "America/New_York", "day": "2026-03-08",
     "sessionKey": "DJIMIC3:20260308", "overrides": {}, "parts": [
        {"partkey": "DJIMIC3/TX_MIC001_20260308_013000/TX01_MIC002_20260308_013000_orig.wav",
         "startedAt": "2026-03-08T01:30:00-05:00", "endedAt": "2026-03-08T03:30:00-05:00",
         "segments": [seg(0, 5000, "before"), seg(2400000, 2405000, "after")]}]},
]

NOTE_FILENAME = [
    {"name": "raw_default", "kind": "raw", "overrides": {}},
    {"name": "raw_colon_template", "kind": "raw", "overrides": {"obsidian.raw.filenameTemplate": "{date}:raw"}},
    {"name": "raw_all_placeholders", "kind": "raw",
     "overrides": {"obsidian.raw.filenameTemplate": "{yyyymmdd}-{date}-{time}"}},
    {"name": "raw_max_bytes_5", "kind": "raw", "overrides": {"obsidian.maxTitleBytes": 5}},
    {"name": "daily_default", "kind": "daily", "overrides": {}},
    {"name": "daily_custom", "kind": "daily", "day": "2026-01-02",
     "overrides": {"obsidian.wiki.filenameTemplate": "{yyyymmdd} 声"}},
    {"name": "raw_folder_default", "kind": "rawFolder", "overrides": {}},
    {"name": "daily_folder_default", "kind": "dailyFolder", "overrides": {}},
]

# --- daily_note --------------------------------------------------------------
ANALYSIS_FULL = {
    "title": "開発と打ち合わせの一日",
    "summary": "VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。",
    "key_points": ["削除の根拠をテキストの保全に置く"],
    "tasks": [{"text": "DJI Mic 3 のマウント構造を確認する", "due": None},
              {"text": "Whisper の速度を実測する", "due": "2026-09-05"}],
    "decisions": ["MVP では GUI を作らない"],
    "ideas": ["将来的に話者識別を追加する"],
    "tags": ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\U00003000空白"],
}
ANALYSIS_MIN = {"title": "題", "summary": "一文目。二文目。", "key_points": [],
                "tasks": [], "decisions": [], "ideas": [], "tags": []}
LINKS_FULL = {"dailyNote": "[[2026-08-29]]", "adjacent": ["[[2026-08-28 Voice]]", "[[2026-08-30 Voice]]"],
              "tags": ["[[VoiceDock]]", "#DJI-Mic"], "raw": ["[[2026-08-29 raw]]"]}
LINKS_RAW_ONLY = {"dailyNote": None, "adjacent": [], "tags": [], "raw": ["[[2026-08-29 raw]]"]}
LINKS_EMPTY = {"dailyNote": None, "adjacent": [], "tags": [], "raw": []}
TL_FULL = {"base": "2026-08-29T07:12:00+09:00", "blocks": [
    {"startMs": 0, "endMs": 4 * 3600000, "lines": ["朝の移動中に整理した", "二点目"]},
    {"startMs": 6 * 3600000, "endMs": 12 * 3600000, "lines": ["MVP を確定した"]}]}
TL_EMPTY = {"base": BASE, "blocks": []}
EX_F = {"partkey": "DJIMIC3/F/f_orig.wav", "status": "FAILED", "errorCode": "WHISPER_FAILED"}
EX_NS = {"partkey": "DJIMIC3/S/s1_orig.wav", "status": "SKIPPED", "errorCode": "NO_SPEECH_DETECTED"}
EX_DUP = {"partkey": "DJIMIC3/S/s2_orig.wav", "status": "SKIPPED", "errorCode": "DUPLICATE_CONTENT"}
EX_SM = {"partkey": "DJIMIC3/S/s3_orig.wav", "status": "SKIPPED", "errorCode": "SOURCE_MISSING"}
EX_NULL = {"partkey": "DJIMIC3/S/s4_orig.wav", "status": "SKIPPED", "errorCode": None}
EX_UNKNOWN = {"partkey": "DJIMIC3/S/s5_orig.wav", "status": "SKIPPED", "errorCode": "LLM_FAILED"}
EX_NM = {"partkey": "DJIMIC3/S/s6_orig.wav", "status": "SKIPPED", "errorCode": "NORMALIZED_MISSING"}


def daily(name: str, **kw) -> dict:
    case = {"name": name, "overrides": {}, "analysis": ANALYSIS_FULL, "recordingKeys": [KA, KB], "excluded": [],
            "recordedSeconds": 34880.9, "blockCount": 2, "timeline": TL_FULL, "links": LINKS_FULL}
    case.update(kw)
    return case


DAILY_NOTE = [
    daily("full", excluded=[EX_F, EX_NS, EX_DUP]),
    daily("minimal", analysis=ANALYSIS_MIN, recordingKeys=[], excluded=[EX_SM, EX_NULL, EX_UNKNOWN],
          recordedSeconds=None, blockCount=0, timeline=TL_EMPTY, links=LINKS_EMPTY),
    daily("no_warnings"),
    daily("failed_only", excluded=[EX_F]),
    daily("skipped_no_speech", excluded=[EX_NS]),
    daily("skipped_dup_and_no_speech_reversed", excluded=[EX_NS, EX_DUP]),
    daily("skipped_actionable_mixed", excluded=[EX_DUP, EX_SM]),
    daily("skipped_missing_both_codes", excluded=[EX_NM, EX_SM]),
    daily("failed_and_skipped_null", excluded=[EX_NULL, EX_F]),
    daily("raw_link_only", links=LINKS_RAW_ONLY),
    daily("no_links", links=LINKS_EMPTY),
    daily("empty_sections", analysis={"title": "空の節", "summary": "要約だけ。",
                                      "key_points": [], "tasks": [], "decisions": [], "ideas": [], "tags": []}),
    daily("order_custom", overrides={"llm.analysis.order": ["summary", "key_points", "timeline"]}),
    daily("ideas_disabled", overrides={"llm.analysis.sections.ideas.enabled": False},
          analysis={k: v for k, v in ANALYSIS_FULL.items() if k != "ideas"}),
    daily("headings_custom", overrides={"llm.analysis.sections.summary.heading": "### 要約",
                                        "llm.analysis.sections.tasks.heading": "## やること"}),
    daily("recorded_over_24h", recordedSeconds=90061.7),
    daily("recorded_negative", recordedSeconds=-5.0),
    daily("body_dashes", analysis={"title": "---題", "summary": "---区切り\n---次",
                                   "key_points": ["---点"], "tasks": [], "decisions": [], "ideas": [], "tags": []}),
    daily("default_tags_custom", overrides={"obsidian.defaultTags": ["Voice", "録音", "voice"]}),
    daily("timeline_empty", timeline=TL_EMPTY),
]

DAILY_PARTS = [
    {"name": "recorded_values", "kind": "recorded",
     "inputs": [None, -1.0, 0.0, 59.999, 60.0, 3599.9, 3600.0, 34880.9, 90061.7, 360000.0]},
    {"name": "tags_adversarial", "kind": "tags", "defaults": ["voice", "voicedock"],
     "tags": ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\U00003000空白",
              "Straße", "STRASSE"]},
    {"name": "tags_missing", "kind": "tags", "defaults": ["voice", "voicedock"], "tags": None},
    {"name": "tags_defaults_dup", "kind": "tags", "defaults": ["Voice", "voice", " x "], "tags": ["X"]},
    {"name": "warnings_cases", "kind": "warnings", "sets": [
        [], [EX_F], [EX_F, EX_F], [EX_NS], [EX_DUP, EX_NS], [EX_SM], [EX_NULL], [EX_UNKNOWN], [EX_NM, EX_SM],
        [EX_F, EX_NS, EX_SM]]},
    {"name": "sentences_cases", "kind": "sentences", "inputs": [
        "", "A。B。 C", "一文目。二文目。\n三文目 。 \n\n四",
        "。。", "no period", "a\U00002028b。c\x1cd"]},
]

# --- timeline ----------------------------------------------------------------
TL_TRANSCRIPT = {
    "segments": [aseg(0, 3200, "一"), aseg(600000, 610000, "二"),
                 aseg(3 * 3600000, 3 * 3600000 + 5000, "三")],
    "blocks": [span(0, 1800000), span(3 * 3600000, 3 * 3600000 + 5000)]}
TIMELINE = [
    {"name": "single_pass_blocks", "base": BASE, "fingerprint": "fp1", "transcript": TL_TRANSCRIPT,
     "summary": "A。B。 C", "partials": [], "chunks": []},
    {"name": "single_pass_fallback_block", "base": BASE, "fingerprint": "fp2",
     "transcript": {"segments": TL_TRANSCRIPT["segments"], "blocks": []},
     "summary": "午前に作業した。午後に会議。", "partials": [], "chunks": []},
    {"name": "single_pass_empty_summary", "base": BASE, "fingerprint": "fp3", "transcript": TL_TRANSCRIPT,
     "summary": "", "partials": [], "chunks": []},
    {"name": "single_pass_no_segments", "base": BASE, "fingerprint": "fp4",
     "transcript": {"segments": [], "blocks": []}, "summary": "A。", "partials": [], "chunks": []},
    {"name": "map_reduce", "base": BASE, "fingerprint": "fp5", "transcript": TL_TRANSCRIPT, "summary": "全体。",
     "partials": [{"summary": "朝。", "key_points": ["点1", "点2"]},
                  {"summary": "X。Y。", "key_points": []}, {"summary": " ", "key_points": []}],
     "chunks": [span(0, 600000), span(600000, 1200000), span(1200000, 1800000)]},
    {"name": "map_reduce_zip_short", "base": BASE, "fingerprint": "fp6", "transcript": TL_TRANSCRIPT,
     "summary": "全体。",
     "partials": [{"summary": "a。", "key_points": []}, {"summary": "b。", "key_points": []},
                  {"summary": "c。", "key_points": []}], "chunks": [span(0, 1000), span(1000, 2000)]},
    {"name": "partials_without_chunks", "base": BASE, "fingerprint": "fp7", "transcript": TL_TRANSCRIPT,
     "summary": "単一。", "partials": [{"summary": "a。", "key_points": []}], "chunks": []},
    {"name": "escapes_in_lines", "base": BASE, "fingerprint": "fp8", "transcript": TL_TRANSCRIPT,
     "summary": "引用\"と\\と/。改行\tタブ。", "partials": [], "chunks": []},
]

TIMELINE_DECODE = [
    {"name": "valid", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "abc", "blocks": [{"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": ["a", "b"]}]}'},
    {"name": "wrong_schema", "fingerprint": "abc",
     "document": '{"schema": 1, "transcript_sha256": "abc", "blocks": []}'},
    {"name": "wrong_fingerprint", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "xyz", "blocks": [{"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": ["a"]}]}'},
    {"name": "bad_elements_skipped", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "abc", "blocks": [1, {"start_at": "x", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": []}, {"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": "a"}, {"start_at": "2026-08-29T08:00:00+09:00", '
        '"end_at": "2026-08-29T09:00:00+09:00", "lines": ["ok", 3]}, {"end_at": "2026-08-29T09:00:00+09:00", '
        '"lines": []}]}'},
    {"name": "not_object", "fingerprint": "abc", "document": "[1, 2]"},
    {"name": "not_json", "fingerprint": "abc", "document": "{"},
    {"name": "blocks_not_list", "fingerprint": "abc",
     "document": '{"schema": 2, "transcript_sha256": "abc", "blocks": {}}'},
]

# --- wiki ----------------------------------------------------------------------
WIKI = [
    {"name": "normalize_names", "kind": "normalize",
     "inputs": ["VoiceDock", "Straße", "STRASSE", "İ", "ﬁle", "ΣΑΣ", "か\U00003099",
                "ＡＢＣ"]},
    {"name": "plan_basic", "kind": "plan", "overrides": {},
     "tags": ["VoiceDock", "none", "a#b", "2026-08-29 Voice"], "indexNames": ["voicedock"],
     "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_max_links_2", "kind": "plan", "overrides": {"obsidian.wiki.maxLinks": 2},
     "tags": ["VoiceDock"], "indexNames": ["VoiceDock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_max_links_0", "kind": "plan", "overrides": {"obsidian.wiki.maxLinks": 0},
     "tags": ["VoiceDock"], "indexNames": ["VoiceDock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_link_tags_false", "kind": "plan", "overrides": {"obsidian.wiki.linkTags": False},
     "tags": ["VoiceDock"], "indexNames": None, "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_link_only_existing_false", "kind": "plan", "overrides": {"obsidian.wiki.linkOnlyExisting": False},
     "tags": ["VoiceDock", "新しい"], "indexNames": [], "rawNames": []},
    {"name": "plan_no_daily_no_adjacent", "kind": "plan",
     "overrides": {"obsidian.wiki.linkDailyNote": False, "obsidian.wiki.linkAdjacentDays": False},
     "tags": ["VoiceDock"], "indexNames": ["voicedock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_index_null", "kind": "plan", "overrides": {}, "tags": ["VoiceDock", " "],
     "indexNames": None, "rawNames": []},
    {"name": "plan_casefold_match", "kind": "plan", "overrides": {}, "tags": ["STRASSE", "ǅ"],
     "indexNames": ["straße", "ǆ"], "rawNames": []},
    {"name": "plan_month_boundary", "kind": "plan", "day": "2026-03-01", "overrides": {}, "tags": [],
     "indexNames": [], "rawNames": ["2026-03-01 raw (2)"]},
    {"name": "plan_bad_raw_name", "kind": "plan", "overrides": {}, "tags": [],
     "indexNames": [], "rawNames": ["a|b", "2026-08-29 raw"]},
    {"name": "index_tree", "kind": "buildIndex", "overrides": {}, "files": [
        "Top.md", "Notes/VoiceDock.md", "Notes/deep/Straße.md", "Notes/UPPER.MD", "Notes/readme.txt",
        ".obsidian/workspace.md", "Notes/.hidden.md", ".trash/old.md",
        "Daily/Voice/Raw/20260829/2026-08-29 raw.md", "Daily/Voice/Rawish/keep.md",
        "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"],
     "symlinkDirs": [["linked", "Notes"]]},
    {"name": "raw_prefix_default", "kind": "rawPrefix", "overrides": {}},
    {"name": "raw_prefix_no_brace", "kind": "rawPrefix", "overrides": {"obsidian.raw.folderTemplate": "Raw/Notes/"}},
    {"name": "raw_prefix_brace_first", "kind": "rawPrefix",
     "overrides": {"obsidian.raw.folderTemplate": "{yyyymmdd}/raw"}},
]

# --- llm -----------------------------------------------------------------------
LLM_SCHEMA_BLOCK = [
    {"name": "final_default", "partial": False, "overrides": {}},
    {"name": "partial_default", "partial": True, "overrides": {}},
    {"name": "final_tags_ideas_disabled", "partial": False,
     "overrides": {"llm.analysis.sections.tags.enabled": False, "llm.analysis.sections.ideas.enabled": False}},
    {"name": "final_maxitems_null", "partial": False,
     "overrides": {"llm.analysis.sections.key_points.maxItems": None}},
    {"name": "partial_tasks_disabled", "partial": True, "overrides": {"llm.analysis.sections.tasks.enabled": False}},
]
LLM_PROMPT = [
    {"name": "analyze_default", "kind": "analyze", "overrides": {}},
    {"name": "analyze_custom", "kind": "analyze",
     "overrides": {"llm.analysis.customInstructions": "健康の話題は要約しない"}},
    {"name": "map_default", "kind": "map", "overrides": {}},
    {"name": "map_custom_multiline", "kind": "map",
     "overrides": {"llm.analysis.customInstructions": "一行目\n二行目"}},
    {"name": "reduce_default", "kind": "reduce", "overrides": {}},
    {"name": "analyze_custom_contains_placeholder", "kind": "analyze",
     "overrides": {"llm.analysis.customInstructions": "{schema_block} は置換しない"}},
]
LLM_REPAIR_PROMPT = [
    {"name": "divergent_final", "partial": False, "overrides": {}, "errors": "- summary: Field required",
     "previousOutput": "{\"title\": \"t\"}"},
    {"name": "divergent_partial", "partial": True, "overrides": {},
     "errors": "- title: Extra inputs are not permitted", "previousOutput": "{\"title\": \"t\", \"summary\": \"s\"}"},
    {"name": "divergent_placeholders_in_output", "partial": False, "overrides": {},
     "errors": "応答から JSON を抽出できませんでした",
     "previousOutput": "{schema_block} {errors} {previous_output}"},
]
LLM_VALIDATE = [
    {"name": n, "partial": p, "overrides": {}, "payload": v} for n, p, v in [
        ("ok_minimal", False, {"title": "t", "summary": "s"}),
        ("ok_full", False, {"title": "t", "summary": "s", "key_points": ["a"], "tasks": [{"text": "x", "due": None}],
                            "decisions": [], "ideas": [], "tags": ["t"]}),
        ("missing_summary", False, {"title": "t"}),
        ("missing_both", False, {}),
        ("extra", False, {"title": "t", "summary": "s", "mood": "x"}),
        ("empty_summary", False, {"title": "t", "summary": ""}),
        ("wrong_list", False, {"title": "t", "summary": "s", "key_points": "文字列"}),
        ("list_item_type", False, {"title": "t", "summary": "s", "key_points": ["a", 1]}),
        ("task_missing_text", False, {"title": "t", "summary": "s", "tasks": [{"due": None}]}),
        ("task_not_dict", False, {"title": "t", "summary": "s", "tasks": ["x"]}),
        ("task_extra", False, {"title": "t", "summary": "s", "tasks": [{"text": "a", "x": 1}]}),
        ("task_due_int", False, {"title": "t", "summary": "s", "tasks": [{"text": "a", "due": 3}]}),
        ("task_due_missing_ok", False, {"title": "t", "summary": "s", "tasks": [{"text": "a"}]}),
        ("task_text_empty", False, {"title": "t", "summary": "s", "tasks": [{"text": ""}]}),
        ("task_text_long", False, {"title": "t", "summary": "s", "tasks": [{"text": "あ" * 501}]}),
        ("title_int", False, {"title": 5, "summary": "s"}),
        ("title_bool", False, {"title": True, "summary": "s"}),
        ("title_too_long", False, {"title": "あ" * 121, "summary": "s"}),
        ("summary_null", False, {"title": "t", "summary": None}),
        ("list_null", False, {"title": "t", "summary": "s", "tags": None}),
        ("multi_order", False, {"mood": 1, "summary": 3, "tags": [1], "zzz": 2}),
        ("partial_with_title_tags", True, {"title": "t", "summary": "s", "tags": ["a"]}),
        ("partial_ok", True, {"summary": "s", "key_points": ["a"]}),
    ]
]
LLM_TRIM = [
    {"name": "trim_all", "partial": False, "overrides": {}, "payload": {
        "title": "あ" * 121, "summary": "s", "tags": [f"t{i}" for i in range(20)],
        "key_points": [f"k{i}" for i in range(25)]}},
    {"name": "trim_exact_limits", "partial": False, "overrides": {}, "payload": {
        "title": "a" * 120, "summary": "s", "tags": [f"t{i}" for i in range(15)]}},
    {"name": "trim_task_text_not_cut", "partial": False, "overrides": {}, "payload": {
        "title": "t", "summary": "s", "tasks": [{"text": "a" * 501, "due": None}]}},
    {"name": "trim_maxitems_null", "partial": False, "overrides": {"llm.analysis.sections.key_points.maxItems": None},
     "payload": {"title": "t", "summary": "s", "key_points": [str(i) for i in range(40)]}},
    {"name": "trim_non_list_ignored", "partial": False, "overrides": {}, "payload": {
        "title": 5, "summary": "s", "tags": "x" * 30}},
]
LLM_EXTRACT = [
    {"name": n, "text": t} for n, t in [
        ("think_prefix", '<think>x</think> {"a":1}'), ("fence_json", '```json\n{"a":1}\n```'),
        ("brace_in_string", 'pre {"a":"}"} post'), ("array_then_object", '[{"a":1}]'),
        ("unclosed_think", '<think>{"a":1}'), ("fence_not_json_then_object", '```\nnot json\n```\n{"b":2}'),
        ("two_fences", '```json\n[1]\n```\n```json\n{"c":3}\n```'), ("plain", '{"x": [1, 2], "y": "z"}'),
        ("escaped_quote", 'noise {"a": "q\\"}"} tail'), ("nothing", "no json here"), ("empty", ""),
        ("think_multiline", '<think>\n{"no":1}\n</think>\n{"yes": true}'), ("nested", '{"a": {"b": {"c": [1]}}}'),
        ("whitespace", '\U00003000 {"a": 1} \U00003000'),
    ]
]
LLM_STRIP_THINK = [
    {"name": n, "text": t} for n, t in [
        ("closed", "<think>x</think>rest"), ("two", "<think>a</think>b<think>c</think>d"),
        ("unclosed", "a<think>b"), ("multiline", "<think>\nx\n</think>\ny"), ("none", "plain"),
    ]
]


def limits(max_chars: int, overlap: int, max_seconds: int) -> dict:
    return {"llm.maxCharsPerRequest": max_chars, "llm.chunkOverlapChars": overlap, "llm.maxSecondsPerRequest": max_seconds}


LLM_CHUNKS = [
    {"name": "v4_example", "base": BASE, "overrides": limits(10, 4, 3600),
     "segments": [aseg(0, 5000, "aaa"), aseg(10000, 15000, "bbb"), aseg(20000, 25000, "ccc"),
                  aseg(30000, 35000, "dd"), aseg(40000, 45000, "eeeee"), aseg(5000000, 5005000, "ff")]},
    {"name": "time_cut_no_overlap", "base": BASE, "overrides": limits(100, 4, 60),
     "segments": [aseg(0, 5000, "a"), aseg(30000, 35000, "b"), aseg(60000, 65000, "c"), aseg(70000, 75000, "d")]},
    {"name": "both_exceeded_no_overlap", "base": BASE, "overrides": limits(5, 2, 60),
     "segments": [aseg(0, 5000, "aaa"), aseg(100000, 105000, "bbb")]},
    {"name": "overlap_takes_at_least_one", "base": BASE, "overrides": limits(10, 1, 3600),
     "segments": [aseg(0, 1000, "aaaa"), aseg(1000, 2000, "bbbbb"), aseg(2000, 3000, "cc")]},
    {"name": "overlap_whole_drops_first", "base": BASE, "overrides": limits(6, 2, 3600),
     "segments": [aseg(0, 1000, "a"), aseg(1000, 2000, "b"), aseg(2000, 3000, "ccccc")]},
    {"name": "single_over_limit", "base": BASE, "overrides": limits(3, 1, 3600),
     "segments": [aseg(0, 1000, "abcdef"), aseg(1000, 2000, "g")]},
    {"name": "multibyte_counts_scalars", "base": BASE, "overrides": limits(5, 2, 3600),
     "segments": [aseg(0, 1000, "あいう"), aseg(1000, 2000, "えお"), aseg(2000, 3000, "か")]},
    {"name": "empty", "base": BASE, "overrides": {}, "segments": []},
    {"name": "default_limits_one_chunk", "base": BASE, "overrides": {},
     "segments": [aseg(0, 1000, "一"), aseg(3000000, 3001000, "二")]},
]
LLM_DEDUPE = [
    {"name": "keys", "kind": "key", "inputs": [" VoiceDock ", "ＶｏｉｃｅＤｏｃｋ",
                                               "ﾃｽﾄ", "Straße", "ﬁle", "ΣΑΣ",
                                               "\U00003000全角空白\U00003000", "\x1cX\x1f", "\U0000200bX", "が",
                                               "か\U00003099"]},
    {"name": "values_first_wins", "kind": "values",
     "inputs": ["A", "a", " A ", "Ａ", "b", "B", "Straße", "STRASSE"]},
    {"name": "result_all_fields", "kind": "result", "overrides": {}, "payload": {
        "title": "t", "summary": "s", "key_points": ["x", "X"],
        "tasks": [{"text": "やる", "due": None}, {"text": " やる ", "due": "2026-09-01"}],
        "decisions": ["d"], "ideas": ["i", "I", "j"], "tags": ["Tag", "tag"]}},
    {"name": "result_empty_lists", "kind": "result", "overrides": {}, "payload": {"title": "t", "summary": "s"}},
]
LLM_AS_JSON = [
    {"name": "escapes_partial", "overrides": {}, "partials": [
        {"summary": "朝/昼\n\"引用\"\t\\\x01", "key_points": ["a"], "tasks": [{"text": "x"}]}]},
    {"name": "two_partials", "overrides": {}, "partials": [{"summary": "s0"}, {"summary": "s1", "ideas": ["i"]}]},
    {"name": "ideas_disabled", "overrides": {"llm.analysis.sections.ideas.enabled": False},
     "partials": [{"summary": "s"}]},
]
LLM_BUNDLES = [
    {"name": "limit_120", "limit": 120, "overrides": {}, "partials": [{"summary": f"s{i}"} for i in range(5)]},
    {"name": "limit_300", "limit": 300, "overrides": {}, "partials": [{"summary": f"s{i}"} for i in range(5)]},
    {"name": "single_oversized", "limit": 10, "overrides": {}, "partials": [{"summary": "long" * 10}, {"summary": "x"}]},
]
ANALYSIS_JSON = [
    {"name": "minimal", "overrides": {}, "payload": {"title": "t", "summary": "s"}},
    {"name": "task_due", "overrides": {}, "payload": {"title": "t", "summary": "s",
                                                      "tasks": [{"text": "x", "due": "2026-09-20"}, {"text": "y"}]}},
    {"name": "tags_disabled", "overrides": {"llm.analysis.sections.tags.enabled": False},
     "payload": {"title": "t", "summary": "s"}},
    {"name": "escapes", "overrides": {}, "payload": {"title": "題/\"x\"", "summary": "改行\nタブ\t\x01",
                                                     "ideas": ["é"]}},
]

# --- transcript / numbers / fingerprint / blocks ------------------------------------
TRANSCRIPT_JSON = [
    {"name": "v4_example", "partkey": KA, "startedAt": BASE, "durationSeconds": 1800.0, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": "ja"}, "transcription": [
         {"offsets": {"from": 0, "to": 3200}, "text": " おはようございます。"},
         {"offsets": {"from": 5500, "to": 9000}, "text": "  "},
         {"offsets": {"from": 9001, "to": 12345}, "text": " 今日は。"},
         {"offsets": {"from": True, "to": 1}, "text": "bool"},
         {"offsets": {"from": 1.5, "to": 2}, "text": "float"}]}},
    {"name": "empty", "partkey": "k", "startedAt": BASE, "durationSeconds": None, "fallbackLanguage": "ja",
     "whisper": {"transcription": []}},
    {"name": "language_fallback", "partkey": KA, "startedAt": BASE, "durationSeconds": 12.5, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": ""}, "transcription": [{"offsets": {"from": 0, "to": 1000}, "text": "a"}]}},
    {"name": "language_en", "partkey": KA, "startedAt": BASE, "durationSeconds": 3.0, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": "en"}, "transcription": [{"offsets": {"from": 0, "to": 1000}, "text": " hi "}]}},
    {"name": "not_object", "partkey": KA, "startedAt": BASE, "durationSeconds": None, "fallbackLanguage": "ja",
     "whisper": [1, 2]},
    {"name": "bad_entries", "partkey": KA, "startedAt": BASE, "durationSeconds": 10.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [1, {"offsets": [0, 1], "text": "x"}, {"offsets": {"from": 0}, "text": "y"},
                                   {"offsets": {"from": 0, "to": 10}, "text": 5},
                                   {"offsets": {"from": "0", "to": 10}, "text": "z"},
                                   {"offsets": {"from": 1234, "to": 5678}, "text": "\U00003000ok\U00003000"}]}},
    {"name": "rounding_ms", "partkey": KA, "startedAt": BASE, "durationSeconds": 7200.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [{"offsets": {"from": 1, "to": 999}, "text": "a"},
                                   {"offsets": {"from": 1234567, "to": 7199999}, "text": "b"},
                                   {"offsets": {"from": 0.4, "to": 0.6}, "text": "c"}]}},
    {"name": "escapes_text", "partkey": KA, "startedAt": BASE, "durationSeconds": 1.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [{"offsets": {"from": 0, "to": 500}, "text": " \"引用\"\\/\t"}]}},
]
NUMBERS = [
    {"name": "whisper_num", "kind": "num", "inputs": [0.5, 1.0, 0.25, 2.0, 0.1, 0.0, 250.0, 1000.0, 0.35]},
    {"name": "whisper_timeout", "kind": "whisperTimeout", "inputs": [None, 10, 199.9, 200, 1800, 7200, 1e9, 0, 200.4]},
    {"name": "convert_timeout", "kind": "convertTimeout", "inputs": [None, 100, 360, 361, 1800.7, 0, 1e6]},
    {"name": "expected_bytes", "kind": "expectedBytes", "inputs": [None, 0, 1.5, 1800, 1800.99999, -5]},
]
FINGERPRINT = [
    {"name": "v4_example", "base": BASE,
     "segments": [aseg(0, 3200, "おはようございます。"),
                  aseg(9001, 12999, "今日は/\"x\"")],
     "blocks": [span(0, 1800000)]},
    {"name": "empty", "base": BASE, "segments": [], "blocks": []},
    {"name": "escapes_and_blocks", "base": BASE,
     "segments": [aseg(0, 1000, "a\nb\t\x01"), aseg(3600000, 3601000, "é\U0001d11e")],
     "blocks": [span(0, 1000), span(3600000, 3601000)]},
]
BLOCKS = [
    {"name": n, "base": "2026-08-29T07:00:00+09:00", "gapSeconds": g, "parts": p} for n, g, p in [
        ("exactly_gap_not_split", 3600, [{"startS": 0, "endS": 1800}, {"startS": 5400, "endS": 6000}]),
        ("one_second_over_splits", 3600, [{"startS": 0, "endS": 1800}, {"startS": 5401, "endS": 6000}]),
        ("overlap_single", 3600, [{"startS": 0, "endS": 1800}, {"startS": 1000, "endS": 2000}]),
        ("contained_keeps_end", 3600, [{"startS": 0, "endS": 7200}, {"startS": 100, "endS": 200}]),
        ("null_end_forces_split", 3600, [{"startS": 0, "endS": None}, {"startS": 60, "endS": 120}]),
        ("zero_gap", 0, [{"startS": 0, "endS": 60}, {"startS": 60, "endS": 120}, {"startS": 121, "endS": 180}]),
        ("empty", 3600, []),
        ("unsorted_input", 3600, [{"startS": 7200, "endS": 7300}, {"startS": 0, "endS": 60}]),
        ("same_start_null_first", 3600, [{"startS": 0, "endS": 60}, {"startS": 0, "endS": None}]),
        ("last_null_end", 3600, [{"startS": 0, "endS": 60}, {"startS": 100, "endS": None}]),
    ]
]

# --- pytext / pyjson ------------------------------------------------------------------
PYTEXT = [
    {"name": "enumerations", "kind": "enumerations"},
    {"name": "strip_cases", "kind": "strip", "inputs": [
        "", "  a  ", "\U00003000a\U00003000", "\x1ca\x1f", "\U0000200ba\U0000200b", "\U00000085a\U000000a0", "\t\n\x0b\x0c\ra b\r\n", "a"]},
    {"name": "strip_dot_cases", "kind": "stripChars", "chars": ".", "inputs": ["..a..", "a.b", "...", "", ". a ."]},
    {"name": "strip_slash_cases", "kind": "stripChars", "chars": "/", "inputs": ["/Daily/Voice/Raw/", "Raw", "//", "/a//"]},
    {"name": "splitlines_cases", "kind": "splitlines", "inputs": [
        "", "\n", "a\n", "a", "a\r\nb\rc\n\nd\x0be\x0cf\x1cg\x1dh\x1ei\x85j\U00002028k\U00002029l\n", "\r\n\r", "a\x1fb",
        "a\r\r\nb"]},
    {"name": "collapse_cases", "kind": "collapse",
     "inputs": ["a  b", "a\t\tb", "a\U00003000\U00003000b", " a ", "a\U0000200bb", "a\x1c\x1db", "a\U000000a0b"]},
    {"name": "casefold_cases", "kind": "casefold", "inputs": [
        "Straße", "ǅ", "ΣΑΣ", "İ", "ﬁ", "ΐ", "ＡＢＣ", "ẞ",
        "Ǆ", "ﬀ", "ŉ", "abc"]},
    {"name": "nfc_cases", "kind": "nfc", "inputs": ["か\U00003099", "e\U00000301", "\U0000212b", "\U00001112\U00001161\U000011ab"]},
    {"name": "nfkc_cases", "kind": "nfkc",
     "inputs": ["ﾃｽﾄ", "Ｖｏｉｃｅ", "①", "㍍", "ﬁ", "\U00003000"]},
]

# PyJSON の値は型付きの配列で表す（整数と浮動小数を区別するため）:
# ["n"] / ["b", 真偽] / ["i", 整数] / ["f", "Python の repr の文字列"] / ["s", 文字列] / ["a", [値…]] / ["o", [[キー, 値]…]]
PYJSON = [
    {"name": "scalars_compact", "mode": "compact", "value": ["a", [
        ["n"], ["b", True], ["b", False], ["i", 0], ["i", -7], ["i", 9007199254740993], ["s", ""]]]},
    {"name": "floats_compact", "mode": "compact", "value": ["a", [["f", r] for r in [
        "0.0", "-0.0", "3.2", "1800.0", "12.345", "1e-05", "0.0001", "1e+16", "1000000000000000.0", "1.5e+300",
        "0.30000000000000004", "123456789.123", "1.2345678901234567e+19", "5e-324", "1.7976931348623157e+308",
        "0.002", "9.001", "2.5e-05", "100.0", "1e+22", "9007199254740992.0", "9007199254740994.0",
        "9500000000000000.0", "-9999999999999998.0", "9.999e-05"]]]},
    {"name": "string_escapes", "mode": "compact",
     "value": ["s", "x\x7f\U00002028/\x01\x1f\b\f\n\r\t\"\\é\U0001d11e"]},
    {"name": "indent_nested", "mode": "indent2", "value": ["o", [
        ["a", ["a", [["i", 1], ["o", [["b", ["a", []]]]]]]], ["c", ["o", []]], ["d", ["s", "日本語"]]]]},
    {"name": "indent_empty_containers", "mode": "indent2", "value": ["a", [["a", []], ["o", []]]]},
    {"name": "indent_top_scalar", "mode": "indent2", "value": ["s", "x"]},
    {"name": "file_transcript_like", "mode": "file", "value": ["o", [
        ["partkey", ["s", KA]], ["language", ["s", "ja"]], ["duration_seconds", ["f", "1800.0"]],
        ["started_at", ["s", BASE]], ["text", ["s", "おはよう"]],
        ["segments", ["a", [["o", [["start", ["f", "0.0"]], ["end", ["f", "3.2"]],
                                   ["text", ["s", "おはよう"]]]]]]]]]},
    {"name": "file_source_json", "mode": "file", "value": ["o", [
        ["schema", ["i", 1]],
        ["transcript_sha256", ["s", "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f"]],
        ["segments", ["i", 2]], ["blocks", ["i", 1]]]]},
    {"name": "order_preserved_compact", "mode": "compact", "value": ["o", [["b", ["i", 1]], ["a", ["i", 2]]]]},
    {"name": "sort_keys_codepoint", "mode": "compact_sorted", "value": ["o", [
        ["b", ["i", 1]], ["\U0001d11e", ["i", 2]], ["Ａ", ["i", 3]], ["a", ["i", 4]], ["ab", ["i", 5]],
        ["a\U00000301", ["i", 6]], ["e", ["i", 7]], ["é", ["i", 8]], ["Z", ["i", 9]]]]},
    {"name": "sort_keys_nested", "mode": "compact_sorted", "value": ["o", [
        ["z", ["o", [["y", ["i", 1]], ["x", ["i", 2]]]]], ["a", ["a", [["o", [["d", ["n"]], ["c", ["b", True]]]]]]]]]},
]

# PyJSON.decode（Python の json.loads 互換）。JSON の本文の中のバックスラッシュは BS で組み立てる。
BS = chr(92)
U = BS + "u"
PYJSON_DECODE = [
    {"name": n, "text": s} for n, s in [
        ("object_basic", '{"a": 1, "b": [true, false, null], "c": "x"}'),
        ("duplicate_key_last_wins_first_position", '{"b":1,"a":2,"b":3}'),
        ("numbers", '[0, -0, 1.0, 1e5, 1E-5, -1.5e+2, 12345678901234567890, 9223372036854775807, '
                    '-9223372036854775808, 9223372036854775808, 0.1, 1e400]'),
        ("constants", '[NaN, Infinity, -Infinity]'),
        ("string_escapes", '"' + U + '3042' + U + 'd834' + U + 'dd1e' + BS + 'n' + BS + '/' + BS + BS + BS + '"'
                           + BS + 'b' + BS + 'f' + BS + 'r' + BS + 't' + U + '00E9"'),
        ("lone_surrogate", '"' + U + 'd800x"'),
        ("ascii_whitespace_around", ' ' + chr(9) + chr(10) + chr(13) + '{"a":1}' + chr(13) + chr(10) + ' '),
        ("ideographic_space_rejected", chr(0x3000) + '{"a":1}'),
        ("extra_data_rejected", '{"a":1} x'),
        ("empty_rejected", ''),
        ("bom_rejected", chr(0xFEFF) + '{}'),
        ("raw_control_char_rejected", '"a' + chr(1) + 'b"'),
        ("raw_tab_in_string_rejected", '"a' + chr(9) + 'b"'),
        ("invalid_escape_rejected", '"' + BS + 'x"'),
        ("short_unicode_escape_rejected", '"' + U + '12"'),
        ("non_string_key_rejected", '{1: 2}'),
        ("trailing_comma_array_rejected", '[1,]'),
        ("trailing_comma_object_rejected", '{"a":1,}'),
        ("leading_zero_rejected", '01'),
        ("minus_only_rejected", '-'),
        ("dot_without_digits_rejected", '1.'),
        ("leading_dot_rejected", '.5'),
        ("nested_ten", '[[[[[[[[[[1]]]]]]]]]]'),
        ("top_string", '"x"'), ("top_number", '3'), ("top_true", 'true'),
        ("non_ascii_raw", '{"' + chr(0x65E5) + '": "' + chr(0x672C) + chr(0x2028) + '"}'),
        ("empty_containers", '{"a": [], "b": {}}'),
    ]
]

# PyRound.round(x, digits)（Python の round(x, n)）。値は repr の文字列で渡す。
PYROUND = [
    {"name": "digits3_ms", "digits": 3, "inputs": ["0.0015", "0.0005", "0.0025", "0.001", "1.2345", "12.3455", "0.0",
                                                  "3.2", "9.001", "1234.5675", "-0.0015", "2.675"]},
    {"name": "digits3_ratios", "digits": 3, "inputs": [repr(1 / 3), repr(2 / 3), repr(12.5 / 1800), repr(0.0625),
                                                      repr(1.0005), repr(123.4565)]},
    {"name": "digits1", "digits": 1, "inputs": ["12.34", "0.05", "0.25", "0.35", "0.45", "2.5", "1e+16", "0.0"]},
]

PROMPT_FILES = [{"name": n} for n in ("analyze_ja", "map_ja", "reduce_ja", "repair_json")]

GROUPS = {
    "keys": KEYS,
    "sanitize": [{"name": n, "input": s, "maxBytes": m} for n, s, m in SANITIZE],
    "frontmatter": FRONTMATTER,
    "raw_note": RAW_NOTE,
    "note_filename": NOTE_FILENAME,
    "daily_note": DAILY_NOTE,
    "daily_parts": DAILY_PARTS,
    "timeline": TIMELINE,
    "timeline_decode": TIMELINE_DECODE,
    "wiki": WIKI,
    "llm_schema_block": LLM_SCHEMA_BLOCK,
    "llm_prompt": LLM_PROMPT,
    "llm_repair_prompt": LLM_REPAIR_PROMPT,
    "llm_validate": LLM_VALIDATE,
    "llm_trim": LLM_TRIM,
    "llm_extract": LLM_EXTRACT,
    "llm_strip_think": LLM_STRIP_THINK,
    "llm_chunks": LLM_CHUNKS,
    "llm_dedupe": LLM_DEDUPE,
    "llm_as_json": LLM_AS_JSON,
    "llm_bundles": LLM_BUNDLES,
    "analysis_json": ANALYSIS_JSON,
    "transcript_json": TRANSCRIPT_JSON,
    "numbers": NUMBERS,
    "fingerprint": FINGERPRINT,
    "blocks": BLOCKS,
    "pytext": PYTEXT,
    "pyjson": PYJSON,
    "pyjson_decode": PYJSON_DECODE,
    "pyround": PYROUND,
    "prompt_files": PROMPT_FILES,
}

# ケースに足す既定（ケースが持っていれば上書きしない）。timeZone は全ケース、day / sessionKey は使うグループだけ
DAY_GROUPS = {"raw_note", "daily_note", "note_filename", "timeline", "wiki", "fingerprint", "llm_chunks"}
SESSION_KEY_GROUPS = {"raw_note", "daily_note"}


def defaults_for(group: str) -> dict:
    values: dict = {"timeZone": TZ}
    if group in DAY_GROUPS:
        values["day"] = DAY
    if group in SESSION_KEY_GROUPS:
        values["sessionKey"] = SK
    return values


INVISIBLE_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Zl", "Zp", "Zs", "Mn", "Mc", "Me"}


def escape_invisible(text: str) -> str:
    """json.dumps(ensure_ascii=False) の結果の中の、見えない文字・空白・結合文字を \\uXXXX にする。

    値は変わらない（JSON の文字列の中にしか現れないため）。レビューで読めるようにするためだけの処理。
    """
    out = []
    for ch in text:
        code = ord(ch)
        if code > 0x7E and unicodedata.category(ch) in INVISIBLE_CATEGORIES:
            if code > 0xFFFF:
                code -= 0x10000
                out.append("\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)))
            else:
                out.append("\\u%04x" % code)
        else:
            out.append(ch)
    return "".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make_inputs.py <Tests/Golden>", file=sys.stderr)
        return 2
    inputs = Path(sys.argv[1]) / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    for old in inputs.glob("*.json"):
        old.unlink()
    for group, cases in GROUPS.items():
        names = [c["name"] for c in cases]
        if len(names) != len(set(names)):
            raise SystemExit(f"{group}: ケース名が重複しています")
        for name in names:
            if not name.replace("_", "").isalnum() or not name.isascii() or name != name.lower():
                raise SystemExit(f"{group}: ケース名は小文字の英数字と _ だけ: {name}")
        extra = defaults_for(group)
        filled = [{**case, **{k: v for k, v in extra.items() if k not in case}} for case in cases]
        doc = {"schema": SCHEMA, "group": group, "cases": filled}
        text = escape_invisible(json.dumps(doc, ensure_ascii=False, indent=2)) + "\n"
        (inputs / f"{group}.json").write_text(text, encoding="utf-8")
    print(f"{len(GROUPS)} グループを書きました: {inputs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
