import argparse
import subprocess


DEFAULT_VERSION = "1.85.1"


def prepare_toolchain(
    version: str = DEFAULT_VERSION,
    targets: list[str] | None = None,
) -> None:
    if targets is None:
        targets = []

    command = [
        "rustup",
        "toolchain",
        "install",
        version,
        "--profile",
        "minimal",
        "--component",
        "cargo",
    ]
    for target in targets:
        command.extend(["--target", target])
    subprocess.run(command, check=True)
    subprocess.run(
        ["rustup", "run", version, "cargo", "--version"],
        check=True,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--target", action="append", default=[])
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    prepare_toolchain(args.version, args.target)

if __name__ == "__main__":
    main()
