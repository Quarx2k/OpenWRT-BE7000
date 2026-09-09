import sys, unittest
from pathlib import Path
from unittest.mock import Mock

P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'installer'))
from kernel_profiles import PROFILES, check_bundle, check_existing, parse_preflight

class KernelSelection(unittest.TestCase):
    def test_both_kernel_reports_are_recognized(self):
        for key in PROFILES:
            self.assertEqual(parse_preflight(f'BE7000_KERNEL_PROFILE={key}\nCompatible\n'.encode()),(key,'Compatible'))

    def test_missing_unknown_or_ambiguous_report_is_rejected(self):
        for data in [b'Compatible',b'BE7000_KERNEL_PROFILE=unknown',
                     b'BE7000_KERNEL_PROFILE=20240122\nBE7000_KERNEL_PROFILE=20260127']:
            with self.assertRaises(ValueError):parse_preflight(data)

    def test_legacy_bundle_is_not_installed_on_2024_kernel(self):
        check_bundle({},'20260127')
        with self.assertRaisesRegex(ValueError,'does not support'):check_bundle({},'20240122')
        for key in PROFILES:check_bundle({'supported_kernels':list(PROFILES)},key)

    def test_existing_installation_must_support_selected_kernel(self):
        run=Mock(return_value=b'20260127\n')
        check_existing(None,run,'/mnt/usb-test/BE7000-OpenWrt','20260127')
        with self.assertRaisesRegex(ValueError,'saved installation'):
            check_existing(None,run,'/mnt/usb-test/BE7000-OpenWrt','20240122')
        run.return_value=b'20240122,20260127\n'
        for key in PROFILES:check_existing(None,run,'/mnt/usb-test/BE7000-OpenWrt',key)

if __name__=='__main__':unittest.main()
