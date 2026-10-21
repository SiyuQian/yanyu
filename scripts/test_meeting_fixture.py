"""Run fixture duration checks without voice hardware or installed voices."""
import importlib.util
import json
import pathlib
import tempfile
import unittest
import wave
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("meeting_fixture", pathlib.Path(__file__).with_name("meeting-fixture.py"))
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class FixtureDurationTests(unittest.TestCase):
    def test_create_fixture_clamps_final_silence(self):
        source = json.loads((pathlib.Path(__file__).resolve().parents[1] / "tests/fixtures/meeting-dialogue.json").read_text())
        voices = "\n".join(voice + " installed" for voice in source["voices"].values())
        def render(command, **_):
            if command[0] == "afconvert":
                with wave.open(command[-1], "wb") as writer:
                    writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    writer.writeframes(b"\0\0" * 48640)  # 3.04 seconds
        with tempfile.TemporaryDirectory() as directory, patch.object(fixture_module.subprocess, "check_output", return_value=voices), patch.object(fixture_module.subprocess, "run", side_effect=render):
            output = pathlib.Path(directory)
            fixture_module.create_fixture(output, 7)
            with wave.open(str(output / "dialogue.wav"), "rb") as reader:
                self.assertEqual(reader.getnframes(), 112000)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["windows"][-1]["end_ms"], 7000)
            self.assertEqual(len(manifest["windows"][-1]["turns"]), 2)


if __name__ == "__main__":
    unittest.main()
