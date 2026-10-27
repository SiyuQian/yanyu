from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare_ascend_evaluation as evaluation


class AscendEvaluationPreparationTests(unittest.TestCase):
    def test_pinned_speaker_independent_splits_have_distinct_contracts(self):
        self.assertEqual(evaluation.split_row_count("test"), 1_315)
        self.assertEqual(evaluation.split_row_count("validation"), 1_130)
        self.assertEqual(evaluation.selected_row_count("test"), 358)
        self.assertEqual(evaluation.selected_row_count("validation"), 191)
        self.assertEqual(
            evaluation.sample_filename("validation", "00001"),
            "validation-mixed-00001.wav",
        )

    def test_selects_only_known_mixed_chinese_english_rows(self):
        rows = [
            {"language": "mixed", "transcription": "你好 app"},
            {"language": "mixed", "transcription": "你好 [UNK]"},
            {"language": "zh", "transcription": "你好"},
            {"language": "mixed", "transcription": "hello there"},
        ]

        self.assertEqual(evaluation.select_mixed_rows(rows), rows[:1])

    def test_detects_cjk_and_latin_text(self):
        self.assertTrue(evaluation.has_han_character("你好"))
        self.assertFalse(evaluation.has_han_character("hello"))
        self.assertTrue(evaluation.has_latin_letter("AI"))
        self.assertFalse(evaluation.has_latin_letter("你好 123"))

    def test_rejects_output_directory_inside_repository(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository_root = Path(temporary_directory) / "repository"
            inside_repository = repository_root / "evaluation-data"
            outside_repository = Path(temporary_directory) / "external-evaluation-data"

            with self.assertRaises(ValueError):
                evaluation.resolve_output_directory(inside_repository, repository_root)

            self.assertEqual(
                evaluation.resolve_output_directory(outside_repository, repository_root),
                outside_repository.resolve(),
            )


if __name__ == "__main__":
    unittest.main()
