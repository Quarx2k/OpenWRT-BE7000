import sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'installer'))
import install

class LocalBundle(unittest.TestCase):
    def test_linux_archive_layout_from_another_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'installer').mkdir()
            bundle=root/f'BE7000-OpenWrt-{install.VERSION}.tar.gz'
            bundle.touch()
            with patch.object(install,'__file__',str(root/'installer/install.py')), patch.object(sys,'frozen',False,create=True):
                self.assertEqual(install.local_bundle(),bundle.resolve())

    def test_windows_bundle_beside_executable(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            bundle=root/f'BE7000-OpenWrt-{install.VERSION}.tar.gz'
            bundle.touch()
            with patch.object(sys,'executable',str(root/'Setup.exe')), patch.object(sys,'frozen',True,create=True):
                self.assertEqual(install.local_bundle(),bundle.resolve())

    def test_absent_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(install,'__file__',str(Path(temp)/'installer/install.py')), patch.object(sys,'frozen',False,create=True):
                self.assertIsNone(install.local_bundle())
