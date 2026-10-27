#!/usr/bin/env python3
"""Download pinned ASCEND mixed-language evaluation fixtures outside the repository."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import wave


DATASET = "CAiRE/ASCEND"
REVISION = "737e9800ae31be9932ba8464c80366559bd28424"
LICENSE = "CC-BY-SA-4.0"
SPLIT_ROWS = {"test": 1_315, "validation": 1_130}
SELECTED_ROWS = {"test": 358, "validation": 191}
BASE_URL = "https://datasets-server.huggingface.co/rows"
USER_AGENT = "YanyuPhase0Evaluation/1.0"


def has_han_character(text: str) -> bool:
    return any(
        "CJK UNIFIED IDEOGRAPH" in unicodedata.name(character, "")
        or "CJK COMPATIBILITY IDEOGRAPH" in unicodedata.name(character, "")
        for character in text
    )


def has_latin_letter(text: str) -> bool:
    return any(character.isascii() and character.isalpha() for character in text)


def select_mixed_rows(rows: list[dict]) -> list[dict]:
    return [
        row
        for row in rows
        if row.get("language") == "mixed"
        and "[UNK]" not in row.get("transcription", "")
        and has_han_character(row.get("transcription", ""))
        and has_latin_letter(row.get("transcription", ""))
    ]


def resolve_output_directory(path: Path, repository_root: Path) -> Path:
    output_directory = path.expanduser().resolve()
    resolved_repository_root = repository_root.resolve()
    try:
        output_directory.relative_to(resolved_repository_root)
    except ValueError:
        return output_directory
    raise ValueError("Keep downloaded speech and transcripts outside the repository.")


def request_json(url: str) -> dict:
    request = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(request, timeout=60) as response:
        return json.load(response)


def split_row_count(split: str) -> int:
    try:
        return SPLIT_ROWS[split]
    except KeyError as error:
        raise ValueError(f"Unsupported ASCEND evaluation split: {split}") from error


def selected_row_count(split: str) -> int:
    try:
        return SELECTED_ROWS[split]
    except KeyError as error:
        raise ValueError(f"Unsupported ASCEND evaluation split: {split}") from error


def sample_filename(split: str, sample_id: str) -> str:
    if not sample_id.isdigit():
        raise ValueError(f"Invalid ASCEND sample identifier: {sample_id!r}")
    split_row_count(split)
    return f"{split}-mixed-{sample_id}.wav"


def fetch_split_rows(split: str) -> list[dict]:
    total_rows = split_row_count(split)
    rows = []
    for offset in range(0, total_rows, 100):
        query = urlencode(
            {
                "dataset": DATASET,
                "config": "main",
                "split": split,
                "offset": offset,
                "length": min(100, total_rows - offset),
                "revision": REVISION,
            }
        )
        payload = request_json(f"{BASE_URL}?{query}")
        if payload.get("num_rows_total") != total_rows:
            raise RuntimeError(f"The pinned ASCEND {split} split row count changed.")
        rows.extend(item["row"] for item in payload["rows"])
    if len(rows) != total_rows:
        raise RuntimeError(f"Expected {total_rows} rows, received {len(rows)}.")
    return rows


def download_sample(row: dict, output_directory: Path, split: str) -> dict:
    sample_id = row["id"]
    filename = sample_filename(split, sample_id)
    source_url = row["audio"][0]["src"]
    last_error = None
    for attempt in range(3):
        try:
            request = Request(source_url, headers={"User-Agent": USER_AGENT})
            with urlopen(request, timeout=60) as response:
                audio_data = response.read()
            with wave.open(io.BytesIO(audio_data), "rb") as audio:
                if (
                    audio.getnchannels() != 1
                    or audio.getframerate() != 16_000
                    or audio.getsampwidth() != 2
                ):
                    raise ValueError(f"Unexpected WAV format for {filename}.")
            (output_directory / filename).write_bytes(audio_data)
            return {
                "id": sample_id,
                "filename": filename,
                "reference": row["transcription"],
                "duration_seconds": row["duration"],
                "language": row["language"],
                "speaker_id": row["original_speaker_id"],
                "session_id": row["session_id"],
                "topic": row["topic"],
                "size_bytes": len(audio_data),
                "sha256": hashlib.sha256(audio_data).hexdigest(),
            }
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as error:
            last_error = error
            if attempt < 2:
                time.sleep(attempt + 1)
    raise RuntimeError(f"Could not download ASCEND sample {sample_id}: {last_error}")


def write_attribution(output_directory: Path) -> None:
    attribution = (
        "ASCEND: A Spontaneous Chinese-English Dataset for Code-switching in Multi-turn Conversation. "
        "Holy Lovenia et al., LREC 2022.\n"
        f"Dataset revision: {REVISION}\n"
        f"License: {LICENSE}. https://creativecommons.org/licenses/by-sa/4.0/\n"
        f"Dataset: https://huggingface.co/datasets/{DATASET}\n"
        "Paper: https://arxiv.org/abs/2112.06223\n"
        "The paper states that speakers gave written consent for recording and publication.\n"
        "Audio and transcripts are temporary evaluation inputs and must stay outside the Yanyu repository.\n"
    )
    (output_directory / "ATTRIBUTION.txt").write_text(attribution, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="External directory for WAVs, references, manifest and attribution.",
    )
    parser.add_argument(
        "--split",
        choices=tuple(SPLIT_ROWS),
        default="test",
        help="Speaker-independent ASCEND evaluation split (default: test).",
    )
    parser.add_argument("--model-name", help="Optional candidate name recorded in the manifest.")
    parser.add_argument("--workers", type=int, default=8)
    arguments = parser.parse_args()
    if arguments.workers < 1 or arguments.workers > 16:
        parser.error("--workers must be between 1 and 16")

    repository_root = Path(__file__).resolve().parents[1]
    output_directory = resolve_output_directory(arguments.output_dir, repository_root)
    output_directory.mkdir(parents=True, exist_ok=True)

    split_rows = fetch_split_rows(arguments.split)
    selected_rows = select_mixed_rows(split_rows)
    expected_selected_rows = selected_row_count(arguments.split)
    if len(selected_rows) != expected_selected_rows:
        raise RuntimeError(
            f"Expected {expected_selected_rows} selected rows, received {len(selected_rows)}."
        )
    with ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        samples = list(
            executor.map(
                lambda row: download_sample(row, output_directory, arguments.split),
                selected_rows,
            )
        )
    samples.sort(key=lambda sample: int(sample["id"]))

    manifest = {
        "dataset": DATASET,
        "revision": REVISION,
        "split": arguments.split,
        "selection": (
            "all language=mixed rows containing Han and Latin letters; references with [UNK] excluded"
        ),
        "license": LICENSE,
        "samples": samples,
    }
    if arguments.model_name:
        manifest["model_name"] = arguments.model_name
    (output_directory / "evaluation-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    write_attribution(output_directory)

    total_bytes = sum(sample["size_bytes"] for sample in samples)
    total_duration = sum(sample["duration_seconds"] for sample in samples)
    print(
        f"dataset={DATASET}@{REVISION} split={arguments.split} samples={len(samples)} "
        f"audio_seconds={total_duration:.1f} bytes={total_bytes} output={output_directory}"
    )


if __name__ == "__main__":
    main()
