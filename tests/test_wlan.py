import io, json, os, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'installer'))
from wlan import MODULES, prepare, collect_missing_acceleration

def fixture(omit=None,extra=None,wrong_arch=False):
    data=io.BytesIO()
    header=bytearray(64);header[:6]=b'\x7fELF\x02\x01';header[18:20]=b'\xb7\x00' if not wrong_arch else b'\x3e\x00'
    module=bytes(header)+b'vermagic=5.4.164 SMP preempt mod_unload aarch64\0'
    with tarfile.open(fileobj=data,mode='w') as t:
        def file(name,body):
            entry=tarfile.TarInfo(name);entry.size=len(body);t.addfile(entry,io.BytesIO(body))
        for n in MODULES:
            if n!=omit:file('lib/modules/5.4.164/'+n+'.ko',module)
        for name in ['ini/global.ini','lib/firmware/IPQ9574/WIFI_FW/q6_fw.mdt','lib/firmware/IPQ9574/WIFI_FW/qcn9224/amss.bin']:
            file(name,b'fixture')
        file('lib/firmware/IPQ9574/caldata.bin',b'private-calibration')
        for name,target in [('lib/firmware/IPQ9574/q6_fw.mdt','WIFI_FW/q6_fw.mdt'),('lib/firmware/qcn9224','IPQ9574/WIFI_FW/qcn9224')]:
            entry=tarfile.TarInfo(name);entry.type=tarfile.SYMTYPE;entry.linkname=target;t.addfile(entry)
        if extra:file(extra,b'forbidden')
    return data.getvalue()

class VendorInputs(unittest.TestCase):
    def test_router_modules_and_aliases_without_rom_version(self):
        with tempfile.TemporaryDirectory() as d:
            output=Path(d)/'wlan.tar.gz'
            report=prepare(fixture(),output,{'release':'5.4.164','build':'January 2026'})
            self.assertEqual(len(report['modules']),12)
            with tarfile.open(output) as t:
                self.assertNotIn('modules/cfg80211.ko',t.getnames())
                self.assertEqual(t.getmember('firmware/IPQ9574/caldata.bin').linkname,'/opt/be7000/calibration/IPQ9574/caldata.bin')
                self.assertEqual(t.getmember('firmware/qcn9224').linkname,'IPQ9574/WIFI_FW/qcn9224')
                self.assertEqual(json.load(t.extractfile('manifest.json'))['kernel']['build'],'January 2026')
    def test_missing_module_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):prepare(fixture(omit='qdf'),Path(d)/'wlan.tar.gz',{})
    def test_optional_acceleration_firmware_is_kept(self):
        with tempfile.TemporaryDirectory() as d:
            output=Path(d)/'wlan.tar.gz'
            report=prepare(fixture(extra='lib/firmware/ifpp.bin'),output,{})
            self.assertEqual(report['acceleration_firmware'],['ifpp.bin'])
            with tarfile.open(output) as t:self.assertEqual(t.extractfile('firmware/ifpp.bin').read(),b'forbidden')
    @unittest.skipUnless(os.name=='posix','requires sh')
    def test_existing_install_adds_only_missing_accelerator_firmware(self):
        with tempfile.TemporaryDirectory() as d:
            source=Path(d)/'source';source.mkdir()
            target=Path(d)/'USB with spaces';dest=target/'device/wlan/firmware';dest.mkdir(parents=True)
            (source/'ifpp.bin').write_bytes(b'new')
            (source/'ipue.bin').write_bytes(b'missing')
            (source/'private.txt').write_bytes(b'private')
            (dest/'ifpp.bin').write_bytes(b'existing')
            def run(client,command):
                return subprocess.check_output(command.replace('/lib/firmware/',str(source)+'/'),shell=True)
            collect_missing_acceleration(None,run,str(target))
            self.assertEqual((dest/'ifpp.bin').read_bytes(),b'existing')
            self.assertEqual((dest/'ipue.bin').read_bytes(),b'missing')
            self.assertEqual({p.name for p in dest.iterdir()},{'ifpp.bin','ipue.bin'})
    def test_wrong_architecture_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):prepare(fixture(wrong_arch=True),Path(d)/'wlan.tar.gz',{})
    def test_unexpected_files_rejected(self):
        for name in ['../../etc/shadow','etc/shadow','lib/modules/5.4.164/cfg80211.ko']:
            with self.subTest(name=name),tempfile.TemporaryDirectory() as d:
                with self.assertRaises(ValueError):prepare(fixture(extra=name),Path(d)/'wlan.tar.gz',{})

if __name__=='__main__':unittest.main()
