#!/usr/bin/env python3
"""Synthesize authored meeting fixtures with installed macOS voices, never downloads."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import wave


def create_fixture(output: pathlib.Path, duration: int = 0) -> None:
    source = pathlib.Path(__file__).resolve().parents[1] / "tests/fixtures/meeting-dialogue.json"
    fixture = json.loads(source.read_text())
    installed = subprocess.check_output(["say", "-v", "?"], text=True)
    for voice in fixture["voices"].values():
        if not any(line.startswith(voice + " ") for line in installed.splitlines()):
            raise RuntimeError(f"Voice is not installed: {voice}; no download attempted")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"source": "Newly authored synthetic dialogue; no personal recordings", "windows": [], "expected": fixture["expected"]}
    cursor = 0
    with tempfile.TemporaryDirectory() as temporary, wave.open(str(output / "dialogue.wav"), "wb") as writer:
        writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        block = 1
        while True:
            for window in fixture["windows"]:
                result = {"block": block, "start_ms": cursor // 16, "turns": []}
                for turn in window["turns"]:
                    text = (f"Block {block}. " if duration else "") + turn["text"]
                    aiff = pathlib.Path(temporary) / "turn.aiff"
                    wav = pathlib.Path(temporary) / "turn.wav"
                    subprocess.run(["say", "-v", fixture["voices"][turn["speaker"]], "-r", "160", "-o", str(aiff), text], check=True)
                    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
                    with wave.open(str(wav), "rb") as reader:
                        count = reader.getnframes()
                        if duration and cursor + count > duration * 16000:
                            writer.writeframes(b"\0\0" * (duration * 16000 - cursor))
                            cursor = duration * 16000
                            result["end_ms"] = cursor // 16
                            manifest["windows"].append(result)
                            (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
                            return
                        audio = reader.readframes(count)
                        samples = memoryview(audio).cast("h")
                        # Keep say's trailing zero frames in the WAV, but not in the speech timing manifest.
                        speech_frames = next((i + 1 for i in range(len(samples) - 1, -1, -1) if samples[i]), 0)
                        result["turns"].append({**turn, "text": text, "start_ms": cursor // 16, "end_ms": (cursor + speech_frames) // 16})
                        writer.writeframes(audio)
                        cursor += count
                    silence = min(8000, duration * 16000 - cursor) if duration else 8000
                    writer.writeframes(b"\0\0" * silence)
                    cursor += silence
                    if duration and cursor == duration * 16000:
                        result["end_ms"] = cursor // 16
                        manifest["windows"].append(result)
                        (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
                        return
                result["end_ms"] = cursor // 16
                manifest["windows"].append(result)
            if not duration:
                break
            block += 1
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--two-hours", action="store_true")
    args = parser.parse_args()
    create_fixture(args.output, 7200 if args.two_hours else 0)
