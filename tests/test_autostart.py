"""Run the real launcher in an isolated Linux root; fake only hardware/transition."""
import contextlib, io, json, os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'installer'))
from autostart import install
import install as installer
from kernel_profiles import PROFILES, render_script

class InstallerTransition(unittest.TestCase):
    def setUp(self):
        tmp=self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(patch.object(installer,'KEYS',Path(tmp)/'known_hosts'))
        self.enterContext(patch.object(sys,'argv',['install.py','--host','192.168.32.1','--action','autostart','--boot-existing']))
        self.enterContext(patch.object(installer.getpass,'getpass',return_value=''))
        self.client=MagicMock()
        inp,out,err=MagicMock(),MagicMock(),MagicMock()
        out.read.return_value=b'BE7000_KERNEL_PROFILE=20260127\nCompatible\n';err.read.return_value=b''
        out.channel.recv_exit_status.return_value=0
        self.client.exec_command.return_value=(inp,out,err)
        self.enterContext(patch.object(installer,'connect_router',return_value=self.client))
        self.enterContext(patch.object(installer,'choose',return_value=1))
        self.confirm=self.enterContext(patch.object(installer,'confirm',return_value=True))
        self.enterContext(patch.object(installer,'ext4_uuid',return_value='00112233-4455-6677-8899-aabbccddeeff'))
        self.events=[]
        def run(client,command,*args):
            self.events.append(command)
            if command=='cat /proc/mounts':return b'/dev/sda1 /mnt/usb-test ext4 rw 0 0\n'
            if command.startswith('readlink'):return b'/sys/devices/usb1/block/sda1\n'
            if 'be7000_source_kernels=' in command:return b'20240122,20260127\n'
            return b''
        self.enterContext(patch.object(installer,'run',side_effect=run))
        self.setup_hook=self.enterContext(patch.object(installer,'install_autostart',side_effect=lambda *args:self.events.append('hook installed')))

    def test_loads_and_executes_after_successful_installation(self):
        installer.main()
        self.assertEqual(self.events[-4],'hook installed')
        self.assertIn('sh 01-load-only.sh LOAD-OWRT12-CANDIDATE',self.events[-3])
        self.assertIn('logs loaded-state.txt',self.events[-2])
        self.assertIn('sh 02-execute.sh EXECUTE-KEXEC-QUIESCED',self.events[-1])
        self.assertFalse(any('reboot' in command for command in self.events))
        self.client.close.assert_called_once()

    def test_installation_failure_does_not_load_kernel(self):
        self.setup_hook.side_effect=RuntimeError('Install failed')
        with self.assertRaisesRegex(RuntimeError,'Install failed'):installer.main()
        self.assertFalse(any('01-load-only' in command or '02-execute' in command for command in self.events))
        self.client.close.assert_called_once()

    def test_2024_profile_uses_same_install_and_boot_path(self):
        self.client.exec_command.return_value[1].read.return_value=b'BE7000_KERNEL_PROFILE=20240122\nCompatible\n'
        installer.main()
        self.setup_hook.assert_called_once()
        self.assertIn('sh 01-load-only.sh LOAD-OWRT12-CANDIDATE',self.events[-3])
        self.assertIn('sh 02-execute.sh EXECUTE-KEXEC-QUIESCED',self.events[-1])

    def test_cancel_does_not_install_or_load_kernel(self):
        self.confirm.return_value=False
        installer.main()
        self.setup_hook.assert_not_called()
        self.assertFalse(any('01-load-only' in command or '02-execute' in command for command in self.events))

class InstallerFiles(unittest.TestCase):
    def test_uuid_has_unix_newline_even_on_windows(self):
        files={}
        def upload(client,path,target):files[target]=path.read_bytes()
        install(None,lambda *args:b'',upload,P/'installer','/mnt/usb-test/BE7000-OpenWrt','00112233-4455-6677-8899-aabbccddeeff')
        self.assertEqual(files['/data/BE7000-OpenWrt/usb.uuid.new'],b'00112233-4455-6677-8899-aabbccddeeff\n')

    def test_bad_uuid_does_not_touch_router(self):
        def unexpected(*args):self.fail('Router was accessed for invalid UUID')
        with self.assertRaises(ValueError):install(None,unexpected,unexpected,P/'installer','/mnt/usb-test/BE7000-OpenWrt','invalid')

@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'requires Linux root and static busybox')
class Autostart(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        busy=Path(os.environ.get('BE7000_TEST_BUSYBOX','/bin/busybox'))
        self.assertTrue(busy.exists(),str(busy))
        self.write('bin/placeholder','')
        shutil.copy2(busy,self.root/'bin/busybox')
        applets=subprocess.check_output([str(busy),'--list'],text=True).splitlines()
        for name in applets:
            if name!='busybox':(self.root/'bin'/name).symlink_to('busybox')
        (self.root/'bin/od').unlink(missing_ok=True)
        (self.root/'bin/nohup').unlink(missing_ok=True)
        for name in ['sleep','sync','logger']:
            self.script('bin/'+name,'exit 0')
        self.set_kernel('20260127')
        self.write('data/BE7000-OpenWrt/usb.uuid','00112233-4455-6677-8899-aabbccddeeff\n')
        self.write('data/BE7000-OpenWrt/autostart.sh',render_script(P/'installer/autostart.sh'))
        self.write('tmp/boot_check_done','boot_done\n')
        self.write('proc/xiaoqiang/boot_status','3\n')
        self.write('sys/kernel/kexec_loaded','0\n')
        self.write('proc/mounts','/dev/sda1 /mnt/usb-test ext4 rw,relatime 0 0\n')
        self.write('dev/null','')
        header=bytearray(2048);header[1128:1144]=bytes.fromhex('00112233445566778899aabbccddeeff')
        (self.root/'dev/sda1').write_bytes(header)
        self.write('sys/devices/usb1/block/sda1/placeholder','')
        self.write('sys/class/block/placeholder','')
        (self.root/'sys/class/block/sda1').symlink_to('/sys/devices/usb1/block/sda1')
        self.base='mnt/usb-test/BE7000-OpenWrt'
        for name in ['READY','BOOT_CONTROL_V1','system.img','userdata.img','payload/launch.conf','boot/installed']:
            self.write(self.base+'/'+name,'1\n')
        self.script(self.base+'/payload/01-load-only.sh','echo loaded >> /tmp/calls; echo state > loaded-state.txt')
        self.script(self.base+'/payload/02-execute.sh','echo executed >> /tmp/calls')
        self.script(self.base+'/payload/03-cancel.sh','echo cancelled >> /tmp/calls')
        self.state=self.root/self.base/'boot'

    def tearDown(self):self.tmp.cleanup()
    def write(self,name,text):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);return p
    def script(self,name,text):
        p=self.root/name
        if p.is_symlink():p.unlink()
        self.write(name,'#!/bin/sh\n'+text+'\n').chmod(0o755)
    def set_kernel(self,profile):
        p=PROFILES[profile]
        self.script('bin/uname',f'case "$1" in -m) echo aarch64;; -r) echo 5.4.164;; -v) echo "{p["build"]}";; esac')
        self.write('proc/kallsyms',p['pen']+' T secondary_holding_pen\n')
    def run_sh(self,*args):
        return subprocess.run(['chroot',str(self.root),'/bin/sh',*args],env={**os.environ,'PATH':'/bin:/usr/sbin'},text=True,capture_output=True)
    def boot(self):return self.run_sh('/data/BE7000-OpenWrt/autostart.sh','run')
    def reboot(self):shutil.rmtree(self.root/'tmp/be7000-autostart.lock')
    def calls(self):
        p=self.root/'tmp/calls';return p.read_text() if p.exists() else ''

    def test_three_attempts_then_stop(self):
        for n in range(1,4):
            self.assertEqual(self.boot().returncode,0)
            self.assertEqual((self.state/'boot-pending').read_text().strip(),str(n))
            self.reboot()
        self.assertIn('Three unconfirmed attempts',self.boot().stdout)
        self.assertEqual(self.calls().count('executed'),3)

    def test_firewall_restart_does_not_retry(self):
        self.boot();self.boot()
        self.assertEqual(self.calls().count('executed'),1)

    def test_detects_kernel_again_after_firmware_change(self):
        self.boot();self.reboot();self.set_kernel('20240122')
        self.assertIn('1.1.16',self.boot().stdout)
        self.assertEqual(self.calls().count('executed'),2)

    def test_wrong_kernel_layout_does_not_consume_attempt(self):
        self.write('proc/kallsyms',PROFILES['20240122']['pen']+' T secondary_holding_pen\n')
        self.assertIn('Unsupported kernel',self.boot().stdout)
        self.assertEqual(self.calls(),'')
        self.assertFalse((self.state/'boot-pending').exists())

    def test_detached_hook_without_nohup(self):
        (self.root/'bin/nohup').unlink(missing_ok=True)
        self.assertEqual(self.run_sh('/data/BE7000-OpenWrt/autostart.sh','start').returncode,0)
        for _ in range(100):
            if 'executed' in self.calls():break
            time.sleep(.02)
        self.assertEqual(self.calls().count('executed'),1)

    def test_skip_once_is_consumed_and_latched(self):
        (self.state/'xiaomi-once').touch()
        self.boot();self.boot()
        self.assertFalse((self.state/'xiaomi-once').exists())
        self.assertEqual(self.calls(),'')
        self.reboot();self.boot()
        self.assertEqual(self.calls().count('executed'),1)

    def test_disabled_preserves_attempts(self):
        (self.state/'autostart-disabled').touch()
        (self.state/'boot-pending').write_text('2\n')
        self.boot()
        self.assertEqual(self.calls(),'')
        self.assertEqual((self.state/'boot-pending').read_text(),'2\n')

    def test_absent_or_different_usb(self):
        for mounts in ['', '/dev/sda1 /mnt/usb-test ext4 ro 0 0\n']:
            self.write('proc/mounts',mounts);self.boot();self.reboot()
            self.assertEqual(self.calls(),'')
        self.write('proc/mounts','/dev/sda1 /mnt/usb-test ext4 rw 0 0\n')
        self.write('data/BE7000-OpenWrt/usb.uuid','ffffffff-ffff-ffff-ffff-ffffffffffff\n')
        self.boot();self.assertEqual(self.calls(),'')

    def test_no_boot_marker_or_old_image(self):
        (self.root/'tmp/boot_check_done').unlink();self.boot()
        self.assertEqual(self.calls(),'')
        self.reboot();self.write('tmp/boot_check_done','boot_done')
        (self.root/self.base/'BOOT_CONTROL_V1').unlink();self.boot()
        self.assertEqual(self.calls(),'')

    def test_bad_counter_fails_closed(self):
        (self.state/'boot-pending').write_text('broken\n');self.boot()
        self.assertEqual(self.calls(),'')

    def test_load_failure_does_not_execute(self):
        self.script(self.base+'/payload/01-load-only.sh','exit 1')
        self.assertEqual(self.boot().returncode,1)
        self.assertEqual(self.calls(),'')
        self.assertEqual((self.state/'boot-pending').read_text(),'1\n')

    def test_existing_loaded_kernel_is_preserved(self):
        self.write('sys/kernel/kexec_loaded','1\n');self.boot()
        self.assertEqual(self.calls(),'')
        self.assertFalse((self.state/'boot-pending').exists())

    def test_kexec_sysfs_absent_before_sender_module_load(self):
        (self.root/'sys/kernel/kexec_loaded').unlink()
        self.assertEqual(self.boot().returncode,0)
        self.assertEqual(self.calls().count('executed'),1)

    def test_success_and_control_flags(self):
        self.boot()
        # Reuse the same USB directory under the OpenWrt mount name.
        (self.root/'mnt/usb').symlink_to('usb-test')
        self.write('proc/mounts','/dev/sda1 /mnt/usb ext4 rw 0 0\n')
        control=self.write('usr/sbin/be7000-boot',(P/'runtime/system/usr/sbin/be7000-boot').read_text())
        def command(name):
            result=self.run_sh('/usr/sbin/be7000-boot',name)
            self.assertEqual(result.returncode,0,result.stderr)
            return result.stdout
        self.assertEqual(json.loads(command('status'))['attempts'],1)
        command('success');self.assertFalse((self.state/'boot-pending').exists())
        command('disable');self.assertFalse(json.loads(command('status'))['enabled'])
        command('xiaomi-once');self.assertTrue(json.loads(command('status'))['xiaomi_once'])
        command('retry');state=json.loads(command('status'))
        self.assertTrue(state['enabled']);self.assertFalse(state['xiaomi_once'])

    def test_confirmation_waits_thirty_seconds(self):
        self.script('bin/ubus','echo "{}"')
        self.script('bin/jsonfilter','cat > /dev/null; echo true')
        self.script('bin/pidof','exit 0')
        self.script('bin/sleep','n=$(cat /tmp/slept 2>/dev/null || echo 0); echo $((n + $1)) > /tmp/slept')
        self.script('usr/sbin/be7000-boot','cp /tmp/slept /tmp/confirmed')
        self.write('confirm.sh',(P/'runtime/system/usr/lib/be7000/boot-confirm.sh').read_text())
        result=self.run_sh('/confirm.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'tmp/confirmed').read_text(),'30\n')

    def test_unhealthy_boot_does_not_clear_counter(self):
        self.script('bin/ubus','exit 1')
        self.script('usr/sbin/be7000-boot','touch /tmp/confirmed')
        self.write('confirm.sh',(P/'runtime/system/usr/lib/be7000/boot-confirm.sh').read_text())
        self.assertEqual(self.run_sh('/confirm.sh').returncode,1)
        self.assertFalse((self.root/'tmp/confirmed').exists())

if __name__=='__main__':unittest.main()
