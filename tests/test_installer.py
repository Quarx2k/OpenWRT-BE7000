import os, re, struct, subprocess, sys, tempfile, unittest
from pathlib import Path
P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'installer'))
from devicetree import spin_table
from storage import ext4_uuid
from kernel_profiles import PROFILES, render_script

class Ext4Identity(unittest.TestCase):
    def header(self):
        data=bytearray(2048)
        data[1080:1082]=b'\x53\xef'
        data[1128:1144]=bytes.fromhex('00112233445566778899aabbccddeeff')
        return data
    def test_filesystem_uuid_byte_order(self):
        self.assertEqual(ext4_uuid(self.header()),'00112233-4455-6677-8899-aabbccddeeff')
    def test_short_read_rejected(self):
        with self.assertRaises(ValueError):ext4_uuid(self.header()[:1144])
    def test_wrong_superblock_rejected(self):
        data=self.header();data[1080:1082]=b'\0\0'
        with self.assertRaises(ValueError):ext4_uuid(data)
    def test_missing_uuid_rejected(self):
        data=self.header();data[1128:1144]=bytes(16)
        with self.assertRaises(ValueError):ext4_uuid(data)

def fixture():
    names=b'enable-method\0local-mac-address\0'
    def node(name):
        b=name.encode()+b'\0';return struct.pack('>I',1)+b+b'\0'*(-len(b)%4)
    def prop(off,b):return struct.pack('>III',3,len(b),off)+b+b'\0'*(-len(b)%4)
    end=struct.pack('>I',2)
    tree=node('')+node('cpus')
    for n in range(4):tree+=node(f'cpu@{n}')+prop(0,b'psci\0')+end
    mac=bytes.fromhex('021122334455')
    tree+=end+node('ethernet')+prop(14,mac)+end+end+struct.pack('>I',9)
    mem=struct.pack('>QQQQ',0x4fa00000,0x200000,0,0)
    st=40+len(mem);strings=st+len(tree);size=strings+len(names)
    return struct.pack('>10I',0xd00dfeed,size,st,strings,40,17,16,0,len(names),len(tree))+mem+tree+names

class DeviceTree(unittest.TestCase):
    def test_only_secondary_cpus_are_changed(self):
        original=fixture();patched=spin_table(original)
        self.assertEqual(patched.count(b'spin-table\0'),3)
        self.assertEqual(patched.count(b'psci\0'),1)
        self.assertIn(bytes.fromhex('021122334455'),patched)
        self.assertEqual(patched[40:72],original[40:72])
        self.assertEqual(struct.unpack_from('>I',patched,4)[0],len(patched))
        self.assertEqual(spin_table(patched),patched)
    def test_wrong_header_rejected(self):
        with self.assertRaises(ValueError):spin_table(b'not a dtb')
    def test_missing_secondary_cpu_rejected(self):
        with self.assertRaises(ValueError):spin_table(fixture().replace(b'cpu@3',b'cpu@9'))

@unittest.skipIf(os.name=='nt','shell fixture runs on Linux')
class StockGate(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        files={'proc/kallsyms':'ffffffc0107f61a4 T secondary_holding_pen\n',
               'proc/mounts':'/dev/mtdblock31 / squashfs ro 0 0\n',
               'proc/cmdline':'ubi.mtd=rootfs root=mtd:ubi_rootfs rootfstype=squashfs ',
               'sys/devices/system/cpu/online':'0-3',
               'sys/firmware/fdt':'qcom,ipq9574-ap-al02-c6',
               'tmp/IPQ9574/caldata.bin':'fixture','tmp/qcn9224/caldata_3.bin':'fixture'}
        for rel,data in files.items():
            f=self.root/rel;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(data)
        self.bin=self.root/'bin';self.bin.mkdir()
        for name,body in {'id':'echo 0','uname':'''case "$1" in
-m) echo aarch64;; -r) echo 5.4.164;; -v) echo "${TEST_KERNEL:-#0 SMP PREEMPT Tue Jan 27 03:33:27 2026}";; esac'''} .items():
            f=self.bin/name;f.write_text('#!/bin/sh\n'+body+'\n');f.chmod(0o755)
        script=render_script(P/'installer/preflight.sh')
        script=re.sub(r'/(proc|sys|tmp)/',lambda m:str(self.root)+m.group(),script)
        self.script=self.root/'check.sh';self.script.write_text(script)
    def tearDown(self):self.temp.cleanup()
    def check(self,**extra):
        env={**os.environ,'PATH':str(self.bin)+':'+os.environ['PATH'],**extra}
        return subprocess.run(['sh',str(self.script)],env=env,capture_output=True).returncode
    def test_supported_stock_passes(self):self.assertEqual(self.check(),0)
    def test_january_2024_kernel_passes(self):
        (self.root/'proc/kallsyms').write_text(PROFILES['20240122']['pen']+' T secondary_holding_pen\n')
        self.assertEqual(self.check(TEST_KERNEL=PROFILES['20240122']['build']),0)
    def test_known_date_with_other_known_layout_rejected(self):
        self.assertNotEqual(self.check(TEST_KERNEL=PROFILES['20240122']['build']),0)
        (self.root/'proc/kallsyms').write_text(PROFILES['20240122']['pen']+' T secondary_holding_pen\n')
        self.assertNotEqual(self.check(),0)
    def test_other_firmware_slot_passes(self):
        (self.root/'proc/mounts').write_text('/dev/mtdblock33 / squashfs ro 0 0\n')
        (self.root/'proc/cmdline').write_text('ubi.mtd=rootfs_1 root=mtd:ubi_rootfs_1 rootfstype=squashfs ')
        self.assertEqual(self.check(),0)
        self.assertNotEqual(self.check(TEST_KERNEL='#20 custom'),0)
    def test_same_release_other_build_rejected(self):self.assertNotEqual(self.check(TEST_KERNEL='#20 custom'),0)
    def test_already_kexec_rejected(self):
        f=self.root/'proc/cmdline';f.write_text(f.read_text()+' boot_source=kexec ')
        self.assertNotEqual(self.check(),0)
    def test_wrong_symbol_rejected(self):
        (self.root/'proc/kallsyms').write_text('ffffffc010000000 T secondary_holding_pen\n')
        self.assertNotEqual(self.check(),0)
    def test_missing_calibration_rejected(self):
        (self.root/'tmp/qcn9224/caldata_3.bin').unlink()
        self.assertNotEqual(self.check(),0)

if __name__=='__main__':unittest.main()
