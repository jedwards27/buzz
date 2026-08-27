"""Build privacy-safe, relay-compatible evidence from a native-review receipt."""
from __future__ import annotations

import hashlib
import json
import math
import pathlib
import re
import shutil
import subprocess
from typing import Any

MAX_VIDEO_EDGE = 2160
SECRET_KEY = re.compile(r"(?i)(?:auth(?:orization)?|token|secret|password|private[_-]?key|cookie|api[_-]?key)")
SECRET_HEADER = re.compile(
    r"(?im)(?P<prefix>^[^\r\n]*?\b(?:authorization|proxy[-_]authorization)\s*[:=]\s*)"
    r"[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*"
)
NSEC_TOKEN = re.compile(r"(?i)(?<![a-z0-9])nsec1[023456789acdefghjklmnpqrstuvwxyz]{20,}(?![a-z0-9])")
SECRET_VALUE = re.compile(
    r"(?i)(?P<name>[\"']?(?:auth|token|secret|password|private[_-]?key|cookie|api[_-]?key)[A-Z0-9_.-]*[\"']?)"
    r"(?P<sep>\s*[:=]\s*)"
    r"(?P<value>\"(?:\\.|[^\"\\\r\n])*\"|'(?:\\.|[^'\\\r\n])*'|[^\r\n]*)(?:\r?\n[ \t]+[^\r\n]*)*"
)


class EvidenceError(RuntimeError):
    pass


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_path(run_dir: pathlib.Path, name: str) -> pathlib.Path:
    candidate = (run_dir / name).resolve()
    if run_dir.resolve() not in candidate.parents or not candidate.is_file():
        raise EvidenceError(f"artifact is missing or escapes receipt directory: {name}")
    return candidate


def record_artifact_digests(receipt: dict[str, Any], run_dir: pathlib.Path) -> None:
    """Bind every receipt-declared file artifact to its final bytes."""
    digests: dict[str, str] = {}
    def visit(value: Any) -> None:
        if isinstance(value, dict):
            for item in value.values():
                visit(item)
        elif isinstance(value, list):
            for item in value:
                visit(item)
        elif isinstance(value, str):
            candidate = (run_dir / value).resolve()
            if run_dir.resolve() in candidate.parents and candidate.is_file():
                digests[value] = sha256(candidate)
    visit(receipt.get("artifacts", {}))
    receipt["artifact_digests"] = dict(sorted(digests.items()))


def verify_artifact(receipt: dict[str, Any], run_dir: pathlib.Path, name: str) -> pathlib.Path:
    path = artifact_path(run_dir, name)
    expected = receipt.get("artifact_digests", {}).get(name)
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise EvidenceError(f"receipt has no valid digest for artifact: {name}")
    if sha256(path) != expected:
        raise EvidenceError(f"artifact digest does not match receipt: {name}")
    return path


def relay_safe_video(source: pathlib.Path, destination: pathlib.Path, *, start: float | None = None,
                     duration: float | None = None) -> pathlib.Path:
    """Transcode a recording to Buzz's canonical, metadata-free MP4 profile."""
    if start is not None and (isinstance(start, bool) or not math.isfinite(start) or start < 0):
        raise EvidenceError("clip start must be finite and non-negative")
    if duration is not None and (isinstance(duration, bool) or not math.isfinite(duration) or duration <= 0):
        raise EvidenceError("clip duration must be finite and positive")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise EvidenceError("ffmpeg is required to finalize shareable evidence")
    if not source.is_file():
        raise EvidenceError(f"recording does not exist: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp.mp4")
    command = [ffmpeg, "-y"]
    if start is not None:
        command.extend(["-ss", str(start)])
    command.extend(["-i", str(source)])
    if duration is not None:
        command.extend(["-t", str(duration)])
    command.extend([
        "-map_metadata", "-1", "-map_chapters", "-1", "-an",
        "-vf", f"scale='min({MAX_VIDEO_EDGE},iw)':'min({MAX_VIDEO_EDGE},ih)':"
               "force_original_aspect_ratio=decrease:force_divisible_by=2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "fast", "-crf", "25",
        "-movflags", "+faststart", "-fflags", "+bitexact", "-flags:v", "+bitexact",
        str(temporary),
    ])
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        temporary.unlink(missing_ok=True)
        diagnostic = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "unknown ffmpeg error"
        raise EvidenceError(f"video finalization failed: {diagnostic}")
    temporary.replace(destination)
    return destination


def redact_log(text: str) -> str:
    def replacement(match: re.Match[str]) -> str:
        value = match.group("value")
        quote = value[0] if value and value[0] in {"\"", "'"} else ""
        return f"{match.group('name')}{match.group('sep')}{quote}[REDACTED]{quote}"
    text = SECRET_HEADER.sub(lambda match: f"{match.group('prefix')}[REDACTED]", text)
    text = SECRET_VALUE.sub(replacement, text)
    return NSEC_TOKEN.sub("[REDACTED]", text)


def redact_value(value: Any) -> Any:
    """Recursively redact credential-shaped keys and strings copied into bundles."""
    if isinstance(value, dict):
        return {
            key: "[REDACTED]" if isinstance(key, str) and SECRET_KEY.search(key) else redact_value(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, str):
        return redact_log(value)
    return value


def focused_log(text: str, match: str | None, context: int) -> str:
    lines = text.splitlines()
    if match is None:
        selected = lines[-200:]
    else:
        try:
            pattern = re.compile(match, re.IGNORECASE)
        except re.error as exc:
            raise EvidenceError(f"invalid log match expression: {exc}") from exc
        indexes = [index for index, line in enumerate(lines) if pattern.search(line)]
        if not indexes:
            raise EvidenceError(f"log match found no lines: {match}")
        included = {
            line_index
            for index in indexes
            for line_index in range(max(0, index - context), min(len(lines), index + context + 1))
        }
        selected = [line for index, line in enumerate(lines) if index in included]
    return redact_log("\n".join(selected) + ("\n" if selected else ""))


def finding_bundle(receipt_path: pathlib.Path, output: pathlib.Path, *, match: str | None = None,
                   context: int = 8, start: float | None = None, duration: float | None = None) -> dict[str, Any]:
    if output.exists():
        raise EvidenceError(f"output already exists: {output}")
    if context < 0:
        raise EvidenceError("log context cannot be negative")
    try:
        receipt = json.loads(receipt_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read receipt {receipt_path}: {exc}") from exc
    if not isinstance(receipt, dict) or not isinstance(receipt.get("artifacts"), dict):
        raise EvidenceError("receipt has no artifact manifest")
    run_dir = receipt_path.parent
    video_name = receipt["artifacts"].get("video")
    log_name = receipt["artifacts"].get("log")
    if not isinstance(video_name, str) or not isinstance(log_name, str):
        raise EvidenceError("finding bundles require receipt video and log artifacts")
    source_receipt_sha256 = sha256(receipt_path)
    video = verify_artifact(receipt, run_dir, video_name)
    log = verify_artifact(receipt, run_dir, log_name)

    output.mkdir(parents=True)
    try:
        relay_safe_video(video, output / "finding.mp4", start=start, duration=duration)
        log_text = log.read_text(errors="replace")
        (output / "log-excerpt.txt").write_text(focused_log(log_text, match, context))
        provenance = receipt.get("provenance", {})
        device = receipt.get("isolation", {}).get("simulator", receipt.get("device", {}))
        receipt_copy = redact_value({
            "schema_version": receipt.get("schema_version"),
            "source_receipt_sha256": source_receipt_sha256,
            "source_artifact_digests": {video_name: receipt["artifact_digests"][video_name],
                                        log_name: receipt["artifact_digests"][log_name]},
            "run_id": receipt.get("run_id"),
            "flow": receipt.get("flow"),
            "status": receipt.get("status"),
            "failure": receipt.get("failure"),
            "provenance": {key: provenance.get(key) for key in ("head_sha", "dirty", "artifact_sha256") if key in provenance},
            "device": {key: device.get(key) for key in ("name", "runtime") if key in device},
            "measurements": receipt.get("measurements"),
            "performance": receipt.get("performance"),
            "cleanup": receipt.get("cleanup"),
        })
        (output / "receipt.json").write_text(json.dumps(receipt_copy, indent=2) + "\n")
        manifest = {
            "schema_version": 1,
            "source_receipt": f"{run_dir.name}/receipt.json",
            "source_receipt_sha256": source_receipt_sha256,
            "source_artifact_digests": {video_name: receipt["artifact_digests"][video_name],
                                        log_name: receipt["artifact_digests"][log_name]},
            "head_sha": receipt.get("provenance", {}).get("head_sha"),
            "dirty": receipt.get("provenance", {}).get("dirty"),
            "status": receipt.get("status"),
            "cleanup": receipt.get("cleanup", {}).get("status"),
            "log_match": match,
            "clip": {"start_seconds": start, "duration_seconds": duration},
            "files": {
                name: {"sha256": sha256(output / name), "size": (output / name).stat().st_size}
                for name in ("finding.mp4", "receipt.json", "log-excerpt.txt")
            },
        }
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
