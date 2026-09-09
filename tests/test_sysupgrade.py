"""USB transaction tests with real ext4 images; run as root in a mount namespace.

BE7000_TEST_FWTOOL=/path/to/fwtool unshare -m python3 -m unittest discover -s tests -p test_sysupgrade.py
Only USB discovery and jsonfilter are substituted. Production staging/commit
code runs on small ext4 fixtures instead of the full-size router images.
"""
import gzip, io, json, os, shutil, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path

P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'tools'))
from sysupgrade import package, FILES

@unittest.skipUnless(os.name=='posix' and os.geteuid()==0 and os.environ.get('BE7000_TEST_FWTOOL'),
                     'requires Linux root, mount namespace and BE7000_TEST_FWTOOL')
class UsbUpgrade(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.base=self.root/'BE7000-OpenWrt'
        self.base.mkdir();(self.base/'slots/a/payload').mkdir(parents=True)
        (self.base/'USB_SLOTS_V1').touch()
        (self.base/'current').symlink_to('slots/a')
        for name in ['system.img','userdata.img','payload']:(self.base/name).symlink_to('current/'+name)
        for name in ['system.img','userdata.img']:(self.base/'slots/a'/name).write_text('original '+name)
        with (self.base/'slots/a/userdata.img').open('r+b') as file:file.truncate(32*1024**2)
        for name in ['launch.conf','be7000-spin-table.dtb']:(self.base/'payload'/name).write_text('device '+name)
        (self.base/'device').mkdir();(self.base/'device/calibration').write_text('keep calibration')
        (self.base/'swap.img').write_text('keep swap')
        self.bindir=self.root/'bin';self.bindir.mkdir()
        (self.bindir/'fwtool').symlink_to(os.environ['BE7000_TEST_FWTOOL'])
        parser=self.bindir/'jsonfilter'
        parser.write_text('#!/usr/bin/env python3\nimport json,sys\nx=json.load(open(sys.argv[2]))\nprint(x["be7000_format"] if sys.argv[4]=="@.be7000_format" else x["supported_devices"][0])\n')
        parser.chmod(0o755)
        script=(P/'runtime/system/usr/lib/be7000/usb-upgrade.sh').read_text()
        begin=script.index('usb_identity() {');end=script.index('\nlayout() {',begin)
        script=script[:begin]+"usb_identity() { uuid=00112233-4455-6677-8899-aabbccddeeff; }\n"+script[end:]
        script=script.replace('base=/mnt/usb/BE7000-OpenWrt','base='+str(self.base))
        script=script.replace('df -Pk /mnt/usb','df -Pk '+str(self.base))
        script=script.replace('/tmp/sysinfo/board_name',str(self.root/'board')).replace('/proc/cmdline',str(self.root/'cmdline'))
        # Keep real host loop/sysfs checks; isolate mountpoints/state/size fixtures.
        script=script.replace('/tmp/be7000-',str(self.root/'be7000-'))
        script=script.replace('536870912','16777216').replace('256|512|1024|2048','16|32|64|128')
        script=script.replace("if ! awk '$2==\"/mnt/usb\" {found=1} END {exit !found}' /proc/mounts; then",'if false; then')
        self.script=self.root/'upgrade.sh';self.script.write_text(script)
        self.env={**os.environ,'PATH':str(self.bindir)+':'+os.environ['PATH']}
        (self.root/'board').write_text('xiaomi,be7000\n')
        (self.root/'cmdline').write_text('boot_source=kexec be7000_usb_uuid=00112233-4455-6677-8899-aabbccddeeff\n')
        self.release=self.root/'release';self.release.mkdir()
        for name in FILES:
            path=self.release/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('test '+name+'\n')
        system=self.root/'system-root';(system/'etc').mkdir(parents=True)
        (system/'etc/be7000-system-id').write_text('new-system\n')
        support=system/'usr/lib/be7000/usb-upgrade.sh';support.parent.mkdir(parents=True);support.write_text('#!/bin/sh\n');support.chmod(0o755)
        data=self.root/'data-root';(data/'upper').mkdir(parents=True);(data/'work').mkdir()
        (data/'base-id').write_text('new-system\n')
        for name,tree,size in [('system',system,16*1024**2),('userdata',data,32*1024**2)]:
            image=self.root/(name+'.img')
            with image.open('wb') as file:file.truncate(size)
            subprocess.run(['mke2fs','-q','-F','-t','ext4','-d',str(tree),str(image)],check=True,stderr=subprocess.DEVNULL)
            with image.open('rb') as source,gzip.open(self.release/(name+'.img.gz'),'wb') as dest:shutil.copyfileobj(source,dest)
        self.image=self.root/'sysupgrade.bin';self.repack()

    def repack(self):package(self.release,self.image,os.environ['BE7000_TEST_FWTOOL'],'1.0.0')
    def run_upgrade(self,mode,*args):
        return subprocess.run(['bash',str(self.script),mode,*map(str,args)],env=self.env,capture_output=True,text=True)
    def active(self):return os.readlink(self.base/'current')
    def stage(self,*args):
        result=self.run_upgrade('stage',self.image,*args)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_stage_and_atomic_commit_preserve_device_files(self):
        self.stage()
        self.assertEqual(self.active(),'slots/a')
        self.assertEqual((self.base/'system.img').read_text(),'original system.img')
        self.assertEqual((self.base/'slots/b/payload/launch.conf').read_text(),'device launch.conf')
        result=self.run_upgrade('commit');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.active(),'slots/b')
        with (self.base/'slots/a/userdata.img').open('rb') as file:
            self.assertEqual(file.read(21),b'original userdata.img')
        self.assertEqual((self.base/'slots/a/userdata.img').stat().st_size,32*1024**2)
        self.assertEqual((self.base/'device/calibration').read_text(),'keep calibration')
        self.assertEqual((self.base/'swap.img').read_text(),'keep swap')

    def test_settings_backup_restored_into_fresh_overlay(self):
        backup=self.root/'backup.tar.gz'
        with tarfile.open(backup,'w:gz') as archive:
            for name,data in [('etc/config/network',b'keep my network'),('etc/be7000-provisioned',b'')]:
                member=tarfile.TarInfo(name);member.size=len(data);archive.addfile(member,io.BytesIO(data))
        self.stage(backup)
        result=subprocess.run(['debugfs','-R','cat upper/etc/config/network',str(self.base/'slots/b/userdata.img')],capture_output=True)
        self.assertEqual(result.stdout,b'keep my network')
        self.assertEqual((self.base/'slots/b/userdata.img').stat().st_size,32*1024**2)

    def test_selected_storage_size_survives_update(self):
        for size in [16,32,64,128]:
            with self.subTest(size=size):
                with (self.base/'slots/a/userdata.img').open('r+b') as file:file.truncate(size*1024**2)
                self.stage()
                image=self.base/'slots/b/userdata.img'
                self.assertEqual(image.stat().st_size,size*1024**2)
                superblock=subprocess.check_output(['dumpe2fs','-h',str(image)],stderr=subprocess.DEVNULL,text=True)
                self.assertIn('Block count:              '+str(size*256)+'\n',superblock)
                result=subprocess.run(['debugfs','-R','cat base-id',str(image)],capture_output=True)
                self.assertEqual(result.stdout,b'new-system\n')

    def test_without_backup_overlay_is_clean(self):
        self.stage()
        result=subprocess.run(['debugfs','-R','ls upper',str(self.base/'slots/b/userdata.img')],capture_output=True,text=True)
        self.assertNotIn('etc',result.stdout)

    def test_wrong_board_rejected_before_writes(self):
        (self.root/'board').write_text('other,router\n')
        self.assertNotEqual(self.run_upgrade('stage',self.image).returncode,0)
        self.assertFalse((self.base/'slots/b').exists());self.assertEqual(self.active(),'slots/a')

    def test_old_flat_layout_requires_installer(self):
        (self.base/'USB_SLOTS_V1').unlink()
        self.assertIn('Recreate',self.run_upgrade('check',self.image).stderr)

    def test_corrupt_rootfs_never_replaces_active_system(self):
        (self.release/'system.img.gz').write_bytes(b'not gzip');self.repack()
        self.assertNotEqual(self.run_upgrade('stage',self.image).returncode,0)
        self.assertEqual(self.active(),'slots/a')
        self.assertFalse((self.base/'slots/b/READY').exists())

    def test_redirected_inactive_slot_rejected(self):
        other=self.root/'unrelated';other.mkdir();(other/'keep').touch()
        (self.base/'slots/b').symlink_to(other)
        self.assertNotEqual(self.run_upgrade('stage',self.image).returncode,0)
        self.assertTrue((other/'keep').exists())

    def test_archive_path_traversal_is_not_extracted(self):
        bad=self.root/'bad.bin'
        with tarfile.open(self.image) as source,tarfile.open(bad,'w') as dest:
            for member in source:dest.addfile(member,source.extractfile(member))
            member=tarfile.TarInfo('../outside');member.size=3
            dest.addfile(member,io.BytesIO(b'bad'))
        subprocess.run([os.environ['BE7000_TEST_FWTOOL'],'-I',str(self.image.with_suffix('.metadata.json')),str(bad)],check=True)
        self.assertNotEqual(self.run_upgrade('stage',bad).returncode,0)
        self.assertFalse((self.root/'outside').exists())
        self.assertFalse((self.base/'slots/b').exists())

    def test_inactive_loop_image_is_not_overwritten(self):
        self.stage()
        loop=subprocess.check_output(['losetup','--find','--show',str(self.base/'slots/b/userdata.img')],text=True).strip()
        try:
            result=self.run_upgrade('stage',self.image)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('still in use',result.stderr)
            self.assertTrue((self.base/'slots/b/READY').exists())
        finally:subprocess.run(['losetup','-d',loop],check=True)

    def test_incomplete_stage_cannot_commit(self):
        self.stage();(self.base/'slots/b/READY').unlink()
        self.assertNotEqual(self.run_upgrade('commit').returncode,0)
        self.assertEqual(self.active(),'slots/a')

    def test_interruption_before_pointer_rename_keeps_old_slot(self):
        self.stage()
        mover=self.bindir/'mv';mover.write_text('#!/bin/sh\nexit 1\n');mover.chmod(0o755)
        self.assertNotEqual(self.run_upgrade('commit').returncode,0)
        self.assertEqual(self.active(),'slots/a')
        mover.unlink()
        self.assertEqual(self.run_upgrade('commit').returncode,0)
        self.assertEqual(self.active(),'slots/b')

if __name__=='__main__':unittest.main()
