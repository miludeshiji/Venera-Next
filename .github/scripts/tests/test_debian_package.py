import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("debian_build", ROOT / "debian/build.py")
debian = importlib.util.module_from_spec(spec)
spec.loader.exec_module(debian)


class DebianPackageTest(unittest.TestCase):
    def bundle(self, root, arch):
        bundle = root / "bundle"
        (bundle / "lib").mkdir(parents=True)
        (bundle / "data/flutter_assets").mkdir(parents=True)
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = (62 if arch == "x64" else 183).to_bytes(2, "little")
        (bundle / "venera-next").write_bytes(header)
        (bundle / "lib/libflutter_linux_gtk.so").write_bytes(b"flutter fixture")
        (bundle / "lib/plugin.so").write_bytes(b"plugin fixture")
        (bundle / "data/icudtl.dat").write_bytes(b"icu fixture")
        (bundle / "data/flutter_assets/fixture.txt").write_text("asset fixture")
        return bundle

    def test_rejects_wrong_architecture_and_non_elf64_headers(self):
        for arch, kind in (("arm64", "machine"), ("x64", "class"),
                           ("x64", "endianness"), ("x64", "magic"), ("x64", "short")):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                bundle = self.bundle(root, "x64")
                binary = bundle / "venera-next"
                header = bytearray(binary.read_bytes())
                if kind == "class":
                    header[4] = 1
                elif kind == "endianness":
                    header[5] = 2
                elif kind == "magic":
                    header[0] = 0
                elif kind == "short":
                    header = header[:19]
                binary.write_bytes(header)
                with self.assertRaisesRegex(ValueError, "ELF64"):
                    debian.stage_package(bundle, root / "stage", arch, "2.2.1")
                self.assertFalse((root / "stage").exists())

    def test_missing_flutter_resources_prevent_staging(self):
        for item in ("lib/libflutter_linux_gtk.so", "data/icudtl.dat", "data/flutter_assets"):
            with self.subTest(item=item), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                bundle = self.bundle(root, "x64")
                resource = bundle / item
                if resource.is_dir():
                    shutil.rmtree(resource)
                else:
                    resource.unlink()
                with self.assertRaisesRegex(ValueError, "Incomplete Flutter bundle"):
                    debian.stage_package(bundle, root / "stage", "x64", "2.2.1")
                self.assertFalse((root / "stage").exists())

    def test_build_failure_preserves_previous_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact = root / "venera-next_2.2.1_amd64.deb"
            artifact.write_bytes(b"previous")

            def failed_build(command, **kwargs):
                Path(command[-1]).write_bytes(b"partial build")
                raise subprocess.CalledProcessError(1, command)

            with patch.object(debian.subprocess, "run", side_effect=failed_build):
                with self.assertRaises(subprocess.CalledProcessError):
                    debian.package_bundle(self.bundle(root, "x64"), root, "x64", "2.2.1+17")
            self.assertEqual(artifact.read_bytes(), b"previous")
            self.assertEqual(list(root.glob(".venera-deb-*")), [])

    def test_invalid_version_cannot_replace_previous_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            artifact = root / "previous.deb"
            artifact.write_bytes(b"previous")
            with self.assertRaises(ValueError):
                debian.package_bundle(self.bundle(root, "x64"), root, "x64", "2.2.1\nInjected: yes")
            self.assertEqual(artifact.read_bytes(), b"previous")
            self.assertEqual(list(root.glob("*.deb")), [artifact])

    @unittest.skipUnless(shutil.which("dpkg"), "Debian version ordering requires dpkg")
    def test_beta_and_rc_sort_before_stable(self):
        for prerelease in ("2.2.1-beta1+17", "2.2.1-rc.1+17"):
            with self.subTest(version=prerelease):
                subprocess.run(["dpkg", "--compare-versions", debian.debian_version(prerelease),
                                "lt", debian.debian_version("2.2.1+17")], check=True)
        subprocess.run(["dpkg", "--compare-versions", debian.debian_version("2.2.1-rc.1"),
                        "lt", debian.debian_version("2.2.1-rc.2")], check=True)

    @unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb requires a Linux runner")
    def test_real_deb_roundtrip_for_both_architectures(self):
        for arch, expected in (("x64", "amd64"), ("arm64", "arm64")):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                bundle = self.bundle(root, arch)
                package = debian.package_bundle(bundle, root / "out", arch, "2.2.1+17")
                control = subprocess.check_output(["dpkg-deb", "--field", str(package)], text=True)
                self.assertIn(f"Architecture: {expected}\n", control)
                self.assertIn("Version: 2.2.1\n", control)
                self.assertIn("Depends: libwebkit2gtk-4.1-0, libgtk-3-0\n", control)
                self.assertIn("Maintainer: miludeshiji/Venera-Next <https://github.com/miludeshiji/Venera-Next>\n", control)
                unpacked = root / "unpacked"
                subprocess.run(["dpkg-deb", "--extract", str(package), str(unpacked)], check=True)
                installed = unpacked / "usr/local/lib/venera-next"
                debian.validate_bundle(installed, arch)
                self.assertEqual((installed / "lib/plugin.so").read_bytes(), b"plugin fixture")
                self.assertEqual((installed / "data/flutter_assets/fixture.txt").read_text(), "asset fixture")
                self.assertTrue((installed / "venera-next").stat().st_mode & 0o111)
                desktop = (unpacked / "usr/share/applications/venera-next.desktop").read_text()
                self.assertIn("Exec=/usr/local/lib/venera-next/venera-next %U\n", desktop)


if __name__ == "__main__":
    unittest.main()
