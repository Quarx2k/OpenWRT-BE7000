import contextlib, io, os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'installer'))
import install
import ui

class InstallationMenu(unittest.TestCase):
    def setUp(self):self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def test_existing_choices_only_inspect_files(self):
        for answer,expected in [('', 'existing'),('2','replace'),('3','cancel')]:
            with self.subTest(answer=answer), patch.object(install,'run',return_value=b'exists\n') as run, patch('builtins.input',return_value=answer):
                self.assertEqual(install.existing_installation(None,'/mnt/usb-test/BE7000-OpenWrt'),expected)
                self.assertEqual(run.call_count,1)
                self.assertNotIn('rm ',run.call_args.args[1])

    def test_new_installation_has_no_extra_prompt(self):
        with patch.object(install,'run',return_value=b''), patch('builtins.input') as ask:
            self.assertEqual(install.existing_installation(None,'/mnt/usb-test/BE7000-OpenWrt'),'new')
            ask.assert_not_called()

    def test_invalid_numbers_retry(self):
        with patch('builtins.input',side_effect=['0','-1','text','4','2']):
            self.assertEqual(ui.choose('Choice',['one','two','three']),2)

    def test_confirmation_default_no_and_retry(self):
        for answers,expected in [([''],False),(['n'],False),(['Y'],True),(['2','y'],True)]:
            with self.subTest(answers=answers), patch('builtins.input',side_effect=answers):
                self.assertEqual(ui.confirm('Proceed?'),expected)

@unittest.skipIf(os.name=='nt','removal guards execute in a Linux fixture')
class RemovalGuards(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.usb=self.root/'usb';self.target=self.usb/install.BASE
        self.target.mkdir(parents=True);(self.target/'userdata.img').write_text('settings')
        self.other=self.usb/'other-file';self.other.write_text('keep')
        (self.root/'mounts').write_text(f'/dev/sda1 {self.usb} ext4 rw,relatime 0 0\n')
        (self.root/'swaps').write_text('Filename Type Size Used Priority\n')
        self.enterContext(patch.object(install,'run',side_effect=self.execute))

    def execute(self,client,command,timeout):
        command=command.replace('/mnt/usb-test',str(self.usb)).replace('/proc/mounts',str(self.root/'mounts')).replace('/proc/swaps',str(self.root/'swaps')).replace('/sys/block',str(self.root/'block'))
        result=subprocess.run(['sh','-c',command],capture_output=True)
        if result.returncode:raise RuntimeError(result.stderr.decode())
        return result.stdout

    def remove(self):install.remove_installation(None,'/dev/sda1','/mnt/usb-test','/mnt/usb-test/'+install.BASE)

    def test_removes_only_selected_installation(self):
        self.remove()
        self.assertFalse(self.target.exists())
        self.assertEqual(self.other.read_text(),'keep')

    def test_changed_usb_rejected(self):
        (self.root/'mounts').write_text(f'/dev/sdb1 {self.usb} ext4 rw 0 0\n')
        with self.assertRaisesRegex(RuntimeError,'mount changed'):self.remove()
        self.assertTrue((self.target/'userdata.img').exists())

    def test_symlink_target_rejected(self):
        other=self.usb/'old';self.target.rename(other);self.target.symlink_to(other)
        with self.assertRaisesRegex(RuntimeError,'redirected'):self.remove()
        self.assertTrue((other/'userdata.img').exists())

    def test_nested_mount_rejected(self):
        with (self.root/'mounts').open('a') as f:f.write(f'/dev/loop0 {self.target}/mounted ext4 rw 0 0\n')
        with self.assertRaisesRegex(RuntimeError,'mounted filesystems'):self.remove()
        self.assertTrue(self.target.exists())

    def test_loop_image_rejected(self):
        backing=self.root/'block/loop0/loop/backing_file';backing.parent.mkdir(parents=True)
        backing.write_text(str(self.target/'userdata.img')+'\n')
        with self.assertRaisesRegex(RuntimeError,'still mounted'):self.remove()
        self.assertTrue(self.target.exists())

    def test_active_swap_rejected(self):
        with (self.root/'swaps').open('a') as f:f.write(f'{self.target}/swap.img file 100 0 -2\n')
        with self.assertRaisesRegex(RuntimeError,'swap is still active'):self.remove()
        self.assertTrue(self.target.exists())

    def test_wrong_target_rejected_before_command(self):
        with patch.object(install,'run') as run:
            with self.assertRaises(ValueError):install.remove_installation(None,'/dev/sda1','/mnt/usb-test','/mnt/usb-test')
            run.assert_not_called()

if __name__=='__main__':unittest.main()
