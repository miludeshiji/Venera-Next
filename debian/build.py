"""Build and package VeneraNext with the system dpkg-deb tool."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DEBIAN_ARCHES = {"x64": "amd64", "arm64": "arm64"}
ELF_MACHINES = {"x64": 62, "arm64": 183}
# Preserve the existing DEB installation directory across upgrades.
INSTALL_PATH = "usr/local/lib/venera-next"


def debian_version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?(?:\+\d+)?", value):
        raise ValueError(f"Unsupported package version: {value}")
    # A tilde orders rc/beta releases before the corresponding stable release.
    return value.partition("+")[0].replace("-", "~", 1)


def validate_bundle(bundle, arch):
    binary = bundle / "venera-next"
    with binary.open("rb") as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:6] != b"\x7fELF\x02\x01"
            or int.from_bytes(header[18:20], "little") != ELF_MACHINES[arch]):
        raise ValueError(f"{binary} is not a Linux {arch} ELF64 binary")
    for item in ("lib/libflutter_linux_gtk.so", "data/icudtl.dat"):
        if not (bundle / item).is_file():
            raise ValueError(f"Incomplete Flutter bundle: missing {item}")
    if not (bundle / "data/flutter_assets").is_dir():
        raise ValueError("Incomplete Flutter bundle: missing data/flutter_assets")


def stage_package(bundle, stage, arch, version):
    validate_bundle(bundle, arch)
    version = debian_version(version)
    destination = stage / INSTALL_PATH
    shutil.copytree(bundle, destination, symlinks=True)
    (destination / "venera-next").chmod(0o755)
    shutil.copyfile(ROOT / "LICENSE", destination / "LICENSE")
    control = stage / "DEBIAN"
    control.mkdir()
    (control / "control").write_text(
        "Package: venera-next\n"
        f"Version: {version}\n"
        f"Architecture: {DEBIAN_ARCHES[arch]}\n"
        "Section: graphics\nPriority: optional\n"
        "Depends: libwebkit2gtk-4.1-0, libgtk-3-0\n"
        "Maintainer: miludeshiji/Venera-Next <https://github.com/miludeshiji/Venera-Next>\n"
        "Description: VeneraNext\n",
        encoding="utf-8",
    )
    applications = stage / "usr/share/applications"
    applications.mkdir(parents=True)
    desktop = (ROOT / "debian/gui/venera-next.desktop").read_text(encoding="utf-8")
    (applications / "venera-next.desktop").write_text(
        desktop.rstrip() + f"\nExec=/{INSTALL_PATH}/venera-next %U\n"
        "MimeType=x-scheme-handler/venera;\n",
        encoding="utf-8",
    )
    icons = stage / "usr/share/icons/hicolor/256x256/apps"
    icons.mkdir(parents=True)
    shutil.copyfile(ROOT / "debian/gui/venera-next.png", icons / "venera-next.png")


def package_bundle(bundle, output, arch, version):
    deb_version = debian_version(version)
    output.mkdir(parents=True, exist_ok=True)
    package = output / f"venera-next_{deb_version}_{DEBIAN_ARCHES[arch]}.deb"
    # Stage on the output filesystem so publication is an atomic replacement.
    with tempfile.TemporaryDirectory(prefix=".venera-deb-", dir=output) as temp:
        stage = Path(temp) / "package"
        stage_package(bundle, stage, arch, version)
        temporary_package = Path(temp) / package.name
        subprocess.run(
            ["dpkg-deb", "--root-owner-group", "--build", str(stage), str(temporary_package)],
            check=True,
        )
        # Failed validation/builds never touch a previously published artifact.
        temporary_package.replace(package)
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=DEBIAN_ARCHES)
    parser.add_argument("--skip-build", action="store_true", help="Package an existing release bundle")
    args = parser.parse_args()
    match = re.search(r"^version:\s*(\S+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if match is None:
        raise ValueError("Missing pubspec version")
    if not args.skip_build:
        subprocess.run(["flutter", "build", "linux", "--release", "--no-pub"], cwd=ROOT, check=True)
    release = ROOT / "build/linux" / args.arch / "release"
    print(package_bundle(release / "bundle", release / "debian", args.arch, match[1]))


if __name__ == "__main__":
    main()
