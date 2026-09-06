import sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from build_version import stamp

class BuildVersion(unittest.TestCase):
    def test_reused_runtime_gets_current_version_once(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'etc').mkdir();(root/'usr/lib').mkdir(parents=True)
            (root/'etc/openwrt_release').write_text("DISTRIB_DESCRIPTION='OpenWrt 25.12.5 / BE7000 by Quarx2k'\n")
            (root/'usr/lib/os-release').write_text('OPENWRT_RELEASE="OpenWrt 25.12.5 / BE7000 by Quarx2k"\n')
            (root/'etc/os-release').symlink_to('../usr/lib/os-release')
            for version in ['v1.0.0','v1.0.0-1-g1234567','v1.0.0-1-g1234567-dirty']:
                with patch('build_version.revision',return_value=version):
                    stamp(root,root);stamp(root,root)
                for name in ['etc/openwrt_release','etc/os-release']:
                    text=(root/name).read_text()
                    self.assertEqual(text.count(' / BE7000'),1)
                    self.assertIn(f'BE7000-OpenWrt {version} by Quarx2k',text)
