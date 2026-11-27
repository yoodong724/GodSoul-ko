#!/usr/bin/env python3
"""Build a KoreanPatch ZIP for the koreanpatch-windows-v2 contract from a patch spec."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import shutil
import struct
import sys
import zipfile
from pathlib import Path
from typing import Any

VERSION = "1.0.0"
SPEC_FORMAT = "koreanpatch-windows-v2/spec-v1"
MANIFEST_FORMAT = "koreanpatch-windows-v2/manifest-v1"
REPORT_FORMAT = "koreanpatch-windows-v2/build-report-v1"
RUNTIME_DIR = Path(__file__).resolve().parent / "KoreanPatch"
RUNTIME_FILES = ("install.cmd", "restore.cmd", "tools/KoreanPatch.ps1")
SPEC_KEYS = {"format", "game_id", "patch_id", "requirements", "operations", "runtime_preconditions", "verification_scope"}
OPERATION_KEYS = {"kind", "path", "payload"}
INVALID_CHARS = re.compile(r'[<>:"|?*\x00-\x1f]')
RESERVED_NAME = re.compile(r"^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$", re.IGNORECASE)
CHUNK = 1024 * 1024


class BuildError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def fail(code: str, message: str) -> None:
    raise BuildError(code, message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("SPEC_INVALID", f"중복된 키가 있습니다: {key}")
        result[key] = value
    return result


def windows_relative(value: Any, label: str, *, game_target: bool) -> str:
    """Apply the same relative path rules as the runtime, before anything is packaged."""
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value:
        fail("PATH_INVALID", f"{label}는 '/'로 구분한 상대 경로여야 합니다: {value!r}")
    segments = value.split("/")
    for segment in segments:
        if (not segment or segment in (".", "..") or INVALID_CHARS.search(segment)
                or segment.endswith((".", " ")) or RESERVED_NAME.match(segment)):
            fail("PATH_INVALID", f"{label}에 Windows에서 쓸 수 없는 경로 조각이 있습니다: {value}")
    if game_target and segments[0].casefold() == "koreanpatch":
        fail("PATH_INVALID", f"{label}가 KoreanPatch 폴더와 겹칩니다: {value}")
    return value


def exists_ignoring_case(path: Path) -> bool:
    """Windows treats names case-insensitively, so match the final name that way too."""
    if path.exists() or path.is_symlink():
        return True
    if not path.parent.is_dir():
        return False
    name = path.name.casefold()
    return any(child.name.casefold() == name for child in path.parent.iterdir())


def overlaps(left: str, right: str) -> bool:
    a, b = left.casefold(), right.casefold()
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def load_spec(path: Path) -> dict[str, Any]:
    try:
        spec = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as exc:
        fail("SPEC_INVALID", f"spec JSON을 읽을 수 없습니다: {exc}")
    if not isinstance(spec, dict) or spec.get("format") != SPEC_FORMAT:
        fail("SPEC_INVALID", f"spec format은 {SPEC_FORMAT}이어야 합니다.")
    unknown = sorted(set(spec) - SPEC_KEYS)
    if unknown:
        fail("SPEC_INVALID", f"알 수 없는 spec 항목: {', '.join(unknown)}")
    for key in ("game_id", "patch_id"):
        if not isinstance(spec.get(key), str) or not spec[key].strip():
            fail("SPEC_INVALID", f"{key}는 비어 있지 않은 문자열이어야 합니다.")
    for key in ("requirements", "operations"):
        if not isinstance(spec.get(key), list) or not spec[key]:
            fail("SPEC_INVALID", f"{key}에는 항목이 하나 이상 있어야 합니다.")
    for key in ("runtime_preconditions", "verification_scope"):
        if key in spec and not isinstance(spec[key], dict):
            fail("SPEC_INVALID", f"{key}는 JSON 객체여야 합니다.")
    return spec


def build_manifest(spec: dict[str, Any], game: Path, payload_dir: Path) -> tuple[dict[str, Any], list[tuple[str, Path]]]:
    requirements = []
    for raw in spec["requirements"]:
        relative = windows_relative(raw, "requirements 경로", game_target=True)
        source = game / relative
        if not source.is_file():
            fail("GAME_FILE_MISSING", f"원본 게임에 확인 파일이 없습니다: {relative}")
        requirements.append({"path": relative, "sha256": sha256_file(source)})

    operations: list[dict[str, Any]] = []
    payload_files: list[tuple[str, Path]] = []
    seen: list[str] = []
    width = max(4, len(str(len(spec["operations"]))))
    for number, raw in enumerate(spec["operations"], start=1):
        if not isinstance(raw, dict) or set(raw) not in (OPERATION_KEYS, OPERATION_KEYS | {"delta_format", "result_size", "after_sha256"}):
            fail("SPEC_INVALID", f"operations {number}번의 필드가 잘못되었습니다.")
        kind = raw["kind"]
        if kind not in ("add", "replace"):
            fail("SPEC_INVALID", f"operations {number}번의 kind는 add 또는 replace여야 합니다.")
        is_delta = "delta_format" in raw
        if is_delta and (kind != "replace" or raw["delta_format"] != "KPDIF001"
                         or type(raw["result_size"]) is not int or raw["result_size"] <= 0
                         or not isinstance(raw["after_sha256"], str)
                         or not re.fullmatch(r"[0-9a-f]{64}", raw["after_sha256"])):
            fail("SPEC_INVALID", f"operations {number}번의 차분 메타데이터가 잘못되었습니다.")
        relative = windows_relative(raw["path"], f"operations {number}번 path", game_target=True)
        for prior in seen:
            if overlaps(relative, prior):
                fail("PATH_CONFLICT", f"대상 경로가 겹칩니다: {prior} / {relative}")
        seen.append(relative)
        target = game / relative
        if kind == "replace":
            if not target.is_file():
                fail("GAME_FILE_MISSING", f"교체할 원본 파일이 없습니다: {relative}")
            before = sha256_file(target)
        else:
            if exists_ignoring_case(target):
                fail("ADD_TARGET_EXISTS", f"추가할 경로가 원본 게임에 이미 있습니다: {relative}")
            before = None
        payload_relative = windows_relative(raw["payload"], f"operations {number}번 payload", game_target=False)
        payload_source = payload_dir / payload_relative
        if not payload_source.is_file():
            fail("PAYLOAD_MISSING", f"payload 파일이 없습니다: {payload_relative}")
        if is_delta:
            with payload_source.open("rb") as stream:
                header = stream.read(24)
            if (len(header) != 24 or header[:8] != b"KPDIF001"
                    or struct.unpack("<Q", header[16:24])[0] != raw["result_size"]):
                fail("SPEC_INVALID", f"operations {number}번의 차분 헤더가 결과 크기와 다릅니다.")
        payload_hash = sha256_file(payload_source)
        # Short numbered names keep KoreanPatch paths well inside the Windows path limit.
        packaged = f"payload/{number:0{width}d}.bin"
        payload_files.append((packaged, payload_source))
        operation = {
            "kind": kind,
            "path": relative,
            "before_sha256": before,
            "payload": packaged,
            "payload_sha256": payload_hash,
            "after_sha256": raw["after_sha256"] if is_delta else payload_hash,
        }
        if is_delta:
            operation.update(delta_format=raw["delta_format"], result_size=raw["result_size"])
        operations.append(operation)

    manifest: dict[str, Any] = {
        "format": MANIFEST_FORMAT,
        "game_id": spec["game_id"],
        "patch_id": spec["patch_id"],
        "requirements": requirements,
        "operations": operations,
    }
    for key in ("runtime_preconditions", "verification_scope"):
        if key in spec:
            manifest[key] = spec[key]
    return manifest, payload_files


def write_zip(out: Path, entries: list[tuple[str, Path | bytes]], stamp: tuple[int, int, int]) -> None:
    with zipfile.ZipFile(out, "x") as archive:
        for name, content in sorted(entries, key=lambda item: item[0]):
            info = zipfile.ZipInfo("KoreanPatch/" + name, date_time=stamp + (0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            if isinstance(content, bytes):
                archive.writestr(info, content)
            else:
                info.file_size = content.stat().st_size
                with content.open("rb") as source, archive.open(info, "w") as target:
                    shutil.copyfileobj(source, target, CHUNK)
    with zipfile.ZipFile(out) as archive:
        if archive.testzip() is not None:
            fail("ZIP_INVALID", "만든 ZIP의 CRC 검사에 실패했습니다.")


def build(args: argparse.Namespace) -> dict[str, Any]:
    game, payload_dir, readme, out = args.game, args.payload_dir, args.readme, args.out
    if not game.is_dir():
        fail("GAME_DIR_MISSING", f"원본 게임 폴더가 없습니다: {game}")
    if not payload_dir.is_dir():
        fail("PAYLOAD_DIR_MISSING", f"payload 폴더가 없습니다: {payload_dir}")
    if not readme.is_file():
        fail("README_MISSING", f"README.ko.txt 파일이 없습니다: {readme}")
    for path in [out] + ([args.report] if args.report else []):
        if path.exists():
            fail("OUTPUT_EXISTS", f"새 파일 경로를 지정하세요. 덮어쓰지 않습니다: {path}")
    if args.report and args.report.resolve() == out.resolve():
        fail("OUTPUT_COLLISION", "--out과 --report는 서로 다른 파일이어야 합니다.")
    for name in RUNTIME_FILES:
        if not (RUNTIME_DIR / name).is_file():
            fail("RUNTIME_MISSING", f"키트 런타임 파일이 없습니다: {name}")
    try:
        stamp = datetime.date.fromisoformat(args.date).timetuple()[:3] if args.date else datetime.date.today().timetuple()[:3]
    except ValueError:
        fail("DATE_INVALID", "--date는 YYYY-MM-DD 형식이어야 합니다.")
    if stamp[0] < 1980:
        fail("DATE_INVALID", "ZIP 날짜는 1980년 이후여야 합니다.")

    spec = load_spec(args.spec)
    manifest, payload_files = build_manifest(spec, game, payload_dir)
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    entries: list[tuple[str, Path | bytes]] = [
        ("README.ko.txt", readme.read_bytes()),
        ("manifest.json", manifest_bytes),
    ]
    entries += [(name, RUNTIME_DIR / name) for name in RUNTIME_FILES]
    entries += payload_files
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        write_zip(out, entries, stamp)
    except FileExistsError:
        raise  # Raised by the exclusive open; the existing file is not ours to remove.
    except BaseException:
        # Do not leave a partial package that could be mistaken for a build result.
        out.unlink(missing_ok=True)
        raise

    operations = manifest["operations"]
    return {
        "format": REPORT_FORMAT,
        "tool_version": VERSION,
        "ok": True,
        "zip": str(out),
        "zip_sha256": sha256_file(out),
        "zip_size": out.stat().st_size,
        "date": "%04d-%02d-%02d" % stamp,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "runtime_sha256": sha256_file(RUNTIME_DIR / "tools/KoreanPatch.ps1"),
        "requirements": len(manifest["requirements"]),
        "operations": {kind: sum(1 for item in operations if item["kind"] == kind) for kind in ("add", "replace")},
        "payload_bytes": sum(path.stat().st_size for _, path in payload_files),
        "longest_target_path": max(len(item["path"]) for item in operations),
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="패치 사양과 원본 게임으로 manifest를 계산하고 KoreanPatch ZIP을 만듭니다.")
    p.add_argument("--version", action="version", version=VERSION)
    p.add_argument("--spec", type=Path, required=True, help="patch spec JSON")
    p.add_argument("--game", type=Path, required=True, help="패치 대상 원본 게임 폴더")
    p.add_argument("--payload-dir", type=Path, required=True, help="spec의 payload 경로 기준 폴더")
    p.add_argument("--readme", type=Path, required=True, help="패키지에 넣을 README.ko.txt")
    p.add_argument("--out", type=Path, required=True, help="새로 만들 ZIP 경로")
    p.add_argument("--date", help="ZIP 항목 날짜 YYYY-MM-DD. 같은 값을 주면 같은 ZIP을 다시 만듭니다.")
    p.add_argument("--report", type=Path, help="결과 보고서를 저장할 새 JSON 경로")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        result = build(args)
        exit_code = 0
    except BuildError as exc:
        result, exit_code = {"ok": False, "error": exc.code, "message": str(exc)}, 2
    except OSError as exc:
        result, exit_code = {"ok": False, "error": "IO_ERROR", "message": str(exc)}, 2
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if exit_code == 0 and args.report:
        with args.report.open("x", encoding="utf-8") as stream:
            stream.write(text + "\n")
    print(text)
    return exit_code


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
