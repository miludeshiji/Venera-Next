import sys
import unittest
from pathlib import Path
from unittest.mock import call, patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from prepare_rust_toolchain import DEFAULT_VERSION, parse_args, prepare_toolchain


class PrepareRustToolchainTest(unittest.TestCase):
    @patch("subprocess.run")
    def test_installs_pinned_toolchain_and_targets_without_uninstall(self, mock_run):
        prepare_toolchain(
            DEFAULT_VERSION,
            ["aarch64-linux-android", "x86_64-linux-android"],
        )

        mock_run.assert_has_calls(
            [
                call(
                    [
                        "rustup",
                        "toolchain",
                        "install",
                        "1.85.1",
                        "--profile",
                        "minimal",
                        "--component",
                        "cargo",
                        "--target",
                        "aarch64-linux-android",
                        "--target",
                        "x86_64-linux-android",
                    ],
                    check=True,
                ),
                call(
                    ["rustup", "run", "1.85.1", "cargo", "--version"],
                    check=True,
                ),
            ]
        )
        self.assertFalse(
            any("uninstall" in invocation.args[0] for invocation in mock_run.call_args_list)
        )

    @patch("subprocess.run")
    def test_repeated_setup_uses_the_same_idempotent_commands(self, mock_run):
        for _ in range(2):
            prepare_toolchain(DEFAULT_VERSION, ["aarch64-linux-android"])

        self.assertEqual(mock_run.call_args_list[:2], mock_run.call_args_list[2:])

    def test_cli_preserves_custom_version_and_repeated_targets(self):
        args = parse_args(
            [
                "--version",
                "1.86.0",
                "--target",
                "aarch64-apple-darwin",
                "--target",
                "x86_64-apple-darwin",
            ]
        )

        self.assertEqual(args.version, "1.86.0")
        self.assertEqual(
            args.target,
            ["aarch64-apple-darwin", "x86_64-apple-darwin"],
        )


if __name__ == "__main__":
    unittest.main()
