#!/usr/bin/env python3
"""Prepare the pinned Chinese and English FLEURS fixtures outside the repository."""

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import wave


DATASET = "google/fleurs"
REVISION = "d7c758a6dceecd54a98cac43404d3d576e721f07"
LICENSE = "CC-BY-4.0"
BASE_URL = f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}"
USER_AGENT = "YanyuPhase0Evaluation/1.0"
FIXTURE_COUNT_PER_LANGUAGE = 8
CACHE_DIRECTORY = Path(tempfile.gettempdir()) / "yanyu-fleurs-cache"
SOURCE_FILES = {
    "zh": {
        "config": "cmn_hans_cn",
        "metadata_sha256": "6b4efd804b543048feb278db06f3b58b5ea171cdd4ba072e328ad630ca25384b",
        "archive_sha256": "3bc33212d5974eef7feb04bc4792458d6cd7e14ff10a1a24772f3c45ea87a822",
    },
    "en": {
        "config": "en_us",
        "metadata_sha256": "9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec",
        "archive_sha256": "2658fda72f199e12676ecac9415094667a4e14e149b146e568ea00b2a2f0954c",
    },
}
SELECTION_RULES = {
    "zh": (
        ("short", lambda text: len(text) <= 26),
        ("long", lambda text: len(text) >= 75),
        ("arabic-numeral", lambda text: bool(re.search(r"\d", text))),
        ("negation", lambda text: bool(re.search(r"不|没|無|无|拒绝|未|非", text))),
        ("quotation-or-parenthesis", lambda text: any(mark in text for mark in '“”"（）()')),
        ("latin-name", lambda text: bool(re.search(r"[A-Z][a-z]+ [A-Z][a-z]+", text))),
    ),
    "en": (
        ("short", lambda text: len(text) <= 55),
        ("long", lambda text: len(text) >= 125),
        ("digits", lambda text: bool(re.search(r"\d", text))),
        (
            "negation",
            lambda text: bool(
                re.search(r"\b(?:not|no|never|without|cannot|didn.t)\b", text, re.I)
            ),
        ),
        ("quotation-or-parenthesis", lambda text: any(mark in text for mark in '“”"()\'')),
        ("proper-name", lambda text: bool(re.search(r"\b[A-Z][a-z]+\s+[A-Z][a-z]+\b", text))),
    ),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_external_directory(path: Path, repository_root: Path) -> Path:
    directory = path.expanduser().resolve()
    try:
        directory.relative_to(repository_root.resolve())
    except ValueError:
        return directory
    raise ValueError("Keep downloaded speech and transcripts outside the repository.")


def download_asset(language: str, kind: str, target: Path) -> Path:
    if language not in SOURCE_FILES or kind not in ("metadata", "archive"):
        raise ValueError(f"Unsupported FLEURS asset: {language}/{kind}")
    expected_sha256 = SOURCE_FILES[language][f"{kind}_sha256"]
    if target.is_file() and sha256_file(target) == expected_sha256:
        return target

    target.parent.mkdir(parents=True, exist_ok=True)
    target.unlink(missing_ok=True)
    config = SOURCE_FILES[language]["config"]
    relative_path = (
        f"data/{config}/dev.tsv" if kind == "metadata" else f"data/{config}/audio/dev.tar.gz"
    )
    request = Request(f"{BASE_URL}/{relative_path}", headers={"User-Agent": USER_AGENT})
    last_error = None
    for attempt in range(3):
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary_file:
                temporary_path = Path(temporary_file.name)
                with urlopen(request, timeout=120) as response:
                    shutil.copyfileobj(response, temporary_file)
            actual_sha256 = sha256_file(temporary_path)
            if actual_sha256 != expected_sha256:
                raise ValueError(
                    f"Pinned FLEURS {language} {kind} hash mismatch: {actual_sha256}"
                )
            os.replace(temporary_path, target)
            return target
        except (HTTPError, URLError, TimeoutError, OSError, ValueError) as error:
            last_error = error
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
            if attempt < 2:
                time.sleep(attempt + 1)
    raise RuntimeError(f"Could not download pinned FLEURS {language} {kind}: {last_error}")


def select_samples(language: str, rows: list[list[str]]) -> list[dict]:
    if language not in SELECTION_RULES:
        raise ValueError(f"Unsupported FLEURS language: {language}")

    unique_by_reference = {}
    for row in rows:
        if len(row) < 6:
            raise ValueError("FLEURS metadata row is incomplete.")
        source_filename = row[1]
        if Path(source_filename).name != source_filename or not source_filename.endswith(".wav"):
            raise ValueError(f"Unsafe FLEURS filename: {source_filename!r}")
        try:
            duration_samples = int(row[5])
        except ValueError as error:
            raise ValueError(f"Invalid FLEURS duration for {source_filename}.") from error
        if duration_samples <= 0:
            raise ValueError(f"Invalid FLEURS duration for {source_filename}.")
        unique_by_reference.setdefault(
            row[2],
            {
                "source_filename": source_filename,
                "reference": row[2],
                "duration_samples": duration_samples,
            },
        )

    candidates = list(unique_by_reference.values())
    selected = []
    selected_filenames = set()
    for category, matches in SELECTION_RULES[language]:
        match = next(
            (
                sample
                for sample in candidates
                if matches(sample["reference"])
                and sample["source_filename"] not in selected_filenames
            ),
            None,
        )
        if match is not None:
            selected.append({**match, "categories": [category]})
            selected_filenames.add(match["source_filename"])

    remaining = sorted(
        (sample for sample in candidates if sample["source_filename"] not in selected_filenames),
        key=lambda sample: (sample["duration_samples"], sample["source_filename"]),
    )
    for sample in remaining:
        if len(selected) >= FIXTURE_COUNT_PER_LANGUAGE:
            break
        selected.append({**sample, "categories": ["additional"]})

    if len(selected) != FIXTURE_COUNT_PER_LANGUAGE:
        raise ValueError(
            f"Expected {FIXTURE_COUNT_PER_LANGUAGE} unique {language} fixtures, "
            f"found {len(selected)}."
        )
    return selected


def prepare_language(
    language: str,
    metadata_path: Path,
    archive_path: Path,
    output_directory: Path,
) -> list[dict]:
    with metadata_path.open(encoding="utf-8", newline="") as metadata_file:
        selected = select_samples(language, list(csv.reader(metadata_file, delimiter="\t")))

    output_directory.mkdir(parents=True, exist_ok=True)
    manifest = []
    with tarfile.open(archive_path, "r:gz") as archive:
        for index, sample in enumerate(selected, start=1):
            member_name = f"dev/{sample['source_filename']}"
            try:
                member = archive.getmember(member_name)
            except KeyError as error:
                raise ValueError(f"Pinned FLEURS archive is missing {member_name}.") from error
            if not member.isfile():
                raise ValueError(f"Pinned FLEURS archive entry is not a file: {member_name}.")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError(f"Could not read FLEURS audio: {member_name}.")
            audio_data = extracted.read()
            with wave.open(io.BytesIO(audio_data), "rb") as audio:
                if (
                    audio.getnchannels() != 1
                    or audio.getframerate() != 16_000
                    or audio.getsampwidth() not in (2, 4)
                    or audio.getnframes() != sample["duration_samples"]
                ):
                    raise ValueError(f"Unexpected WAV format for {member_name}.")

            filename = f"{language}_{index:02}.wav"
            (output_directory / filename).write_bytes(audio_data)
            manifest.append(
                {
                    "language": language,
                    "filename": filename,
                    "source_filename": sample["source_filename"],
                    "reference": sample["reference"],
                    "duration_ms": sample["duration_samples"] * 1000 // 16_000,
                    "categories": sample["categories"],
                    "sha256": hashlib.sha256(audio_data).hexdigest(),
                }
            )
    return manifest


def write_attribution(output_directory: Path) -> None:
    attribution = (
        "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech.\n"
        f"Dataset: {DATASET}@{REVISION}\n"
        f"License: {LICENSE}. https://creativecommons.org/licenses/by/4.0/\n"
        f"Dataset card: https://huggingface.co/datasets/{DATASET}\n"
        "Paper: https://arxiv.org/abs/2205.12446\n"
        "Only the selected dev fixtures are written here. Keep audio and transcripts outside Git.\n"
    )
    (output_directory / "ATTRIBUTION.txt").write_text(attribution, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="External directory for selected WAVs, manifest and attribution.",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=CACHE_DIRECTORY,
        help=f"External cache for pinned source files (default: {CACHE_DIRECTORY}).",
    )
    arguments = parser.parse_args()

    repository_root = Path(__file__).resolve().parents[1]
    output_directory = resolve_external_directory(arguments.output_dir, repository_root)
    cache_directory = resolve_external_directory(arguments.cache_dir, repository_root)
    output_directory.mkdir(parents=True, exist_ok=True)
    cache_directory.mkdir(parents=True, exist_ok=True)

    samples = []
    for language in ("zh", "en"):
        metadata_path = download_asset(
            language, "metadata", cache_directory / f"{language}-dev.tsv"
        )
        archive_path = download_asset(
            language, "archive", cache_directory / f"{language}-dev.tar.gz"
        )
        samples.extend(
            prepare_language(language, metadata_path, archive_path, output_directory)
        )

    manifest = {
        "dataset": DATASET,
        "revision": REVISION,
        "license": LICENSE,
        "selection": (
            "First unique-reference match for six language-specific categories, then the "
            "shortest remaining unique references; eight fixtures per language."
        ),
        "samples": samples,
    }
    (output_directory / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    write_attribution(output_directory)
    print(
        f"dataset={DATASET}@{REVISION} samples={len(samples)} output={output_directory}"
    )


if __name__ == "__main__":
    main()
