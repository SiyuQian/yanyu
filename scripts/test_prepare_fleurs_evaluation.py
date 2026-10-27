from pathlib import Path
import io
import sys
import tarfile
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare_fleurs_evaluation as evaluation


class FleursEvaluationPreparationTests(unittest.TestCase):
    def test_selection_covers_categories_then_fills_with_shortest_unique_samples(self):
        rows = [
            self.row("short.wav", "短句"),
            self.row("long.wav", "长" * 80),
            self.row("digits.wav", "第42项"),
            self.row("negation.wav", "没有问题"),
            self.row("quotes.wav", "“引号”"),
            self.row("name.wav", "Alice Smith"),
            self.row("fallback-long.wav", "补充甲", 32_000),
            self.row("fallback-short.wav", "补充乙", 16_000),
            self.row("duplicate.wav", "补充乙", 8_000),
        ]

        selected = evaluation.select_samples("zh", rows)

        self.assertEqual(
            [sample["source_filename"] for sample in selected],
            [
                "short.wav",
                "long.wav",
                "digits.wav",
                "negation.wav",
                "quotes.wav",
                "name.wav",
                "fallback-short.wav",
                "fallback-long.wav",
            ],
        )
        self.assertEqual(selected[0]["categories"], ["short"])
        self.assertEqual(selected[-2]["categories"], ["additional"])

    def test_prepares_hashed_wav_manifest_from_a_local_fleurs_archive(self):
        rows = [
            self.row("short.wav", "短句"),
            self.row("long.wav", "长" * 80),
            self.row("digits.wav", "第42项"),
            self.row("negation.wav", "没有问题"),
            self.row("quotes.wav", "“引号”"),
            self.row("name.wav", "Alice Smith"),
            self.row("fallback-a.wav", "补充甲", 32_000),
            self.row("fallback-b.wav", "补充乙", 16_000),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            tsv_path = root / "dev.tsv"
            archive_path = root / "dev.tar.gz"
            output_directory = root / "output"
            tsv_path.write_text(
                "\n".join("\t".join(row) for row in rows) + "\n", encoding="utf-8"
            )
            with tarfile.open(archive_path, "w:gz") as archive:
                for row in rows:
                    content = self.wav(int(row[5]))
                    info = tarfile.TarInfo(f"dev/{row[1]}")
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))

            manifest = evaluation.prepare_language(
                "zh", tsv_path, archive_path, output_directory
            )

            self.assertEqual(len(manifest), 8)
            self.assertEqual(manifest[0]["filename"], "zh_01.wav")
            self.assertEqual(manifest[0]["duration_ms"], 1_000)
            self.assertRegex(manifest[0]["sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(
                (output_directory / manifest[0]["filename"]).read_bytes(),
                self.wav(int(rows[0][5])),
            )

    def test_rejects_unsupported_language(self):
        with self.assertRaises(ValueError):
            evaluation.select_samples("fr", [])

    @staticmethod
    def row(filename, reference, frame_count=16_000):
        return ["1", filename, reference, reference, reference, str(frame_count), "FEMALE"]

    @staticmethod
    def wav(frame_count):
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16_000)
            audio.writeframes(b"\0\0" * frame_count)
        return buffer.getvalue()


if __name__ == "__main__":
    unittest.main()
