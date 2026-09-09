#!/usr/bin/env python3
"""Build OpenWrt, QSDK kernel, runtime and clean USB images on Linux."""
from pathlib import Path
import argparse, subprocess, shutil, tarfile, gzip, os, stat, re, json, urllib.request, sys
from build_runtime import bootstrap
from build_kmods import package as package_kmods
from build_version import stamp
from sysupgrade import package as package_sysupgrade

P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'installer'))
from kernel_profiles import PROFILES, render_script
VERSION='1.0.1'
REPO='https://github.com/Quarx2k/OpenWRT-BE7000.git'
KERNEL='50fdc574baa2d3bfe3ab36be8f6d362441e6cd6f'
STOCK='65a4446d0e6c21d084ca69317641515da4bd22aa'

def run(*args):subprocess.run(list(map(str,args)),check=True)

def cpio(root,dest):
    output=bytearray();ino=0
    def add(name,mode,data=b'',major=0,minor=0):
        nonlocal ino
        ino+=1
        fields=[ino,mode,0,0,1,0,len(data),0,0,major,minor,len(name.encode())+1,0]
        output.extend(b'070701'+''.join(f'{v:08x}' for v in fields).encode()+name.encode()+b'\0')
        output.extend(b'\0'*(-len(output)%4));output.extend(data);output.extend(b'\0'*(-len(output)%4))
    for f in sorted(root.rglob('*')):
        s=f.lstat();name=str(f.relative_to(root))
        if f.is_symlink():add(name,s.st_mode,os.readlink(f).encode())
        elif f.is_dir():add(name,s.st_mode)
        elif f.is_file():add(name,s.st_mode,f.read_bytes())
        elif stat.S_ISCHR(s.st_mode):add(name,s.st_mode,major=os.major(s.st_rdev),minor=os.minor(s.st_rdev))
        else:raise ValueError(f'Unexpected initramfs file: {f}')
    if not (root/'dev/console').exists():add('dev/console',stat.S_IFCHR|0o600,major=5,minor=1)
    add('TRAILER!!!',0);dest.write_bytes(gzip.compress(output,compresslevel=9,mtime=0))

def source(work,name,branch,revision,override):
    path=override or work/name
    if not path.exists():run('git','clone','--single-branch','--branch',branch,REPO,path)
    head=subprocess.check_output(['git','-c','safe.directory='+str(path),'-C',str(path),'rev-parse','HEAD'],text=True).strip()
    if head!=revision:raise ValueError(f'{name}: expected pinned commit {revision}, got {head}')
    return path

def main():
    a=argparse.ArgumentParser(description=__doc__)
    a.add_argument('--work',type=Path,default=Path.home()/'be7000-build')
    a.add_argument('--runtime-kit',type=Path,help='Reuse a prebuilt runtime instead of building its components')
    a.add_argument('--kernel-dir',type=Path);a.add_argument('--stock-dir',type=Path)
    a.add_argument('--cross-compile');a.add_argument('-j',type=int,default=min(os.cpu_count() or 4,16))
    args=a.parse_args();w=args.work.resolve();w.mkdir(parents=True,exist_ok=True)
    if str(w).startswith('/mnt/'):raise ValueError('Use a Linux filesystem for --work, e.g. ~/be7000-build')
    if os.geteuid()!=0:raise ValueError('Run through sudo to preserve rootfs ownership and device nodes')
    k=source(w,'linux','kernel-qsdk-12.1-r5',KERNEL,args.kernel_dir)
    stock=source(w,'stock-linux-r5','stock-abi-qsdk-12.1-r5-20260127',STOCK,args.stock_dir)
    cross=args.cross_compile
    if not cross:
        tc=w/'toolchain';tc.mkdir(exist_ok=True)
        tool=tc/'gcc-7.5.0-nolibc/aarch64-linux/bin/aarch64-linux-gcc'
        if not tool.exists():
            archive=tc/'gcc.tar.xz'
            urllib.request.urlretrieve('https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/x86_64/7.5.0/x86_64-gcc-7.5.0-nolibc-aarch64-linux.tar.xz',archive)
            with tarfile.open(archive) as t:t.extractall(tc,filter='data')
        cross=str(tool)[:-3]
    run(cross+'gcc','--version')
    b=w/'kernel-build';b.mkdir(exist_ok=True)
    if not (b/'.config').exists():shutil.copy2(P/'configs/kernel.config',b/'.config')
    if args.runtime_kit:
        kit=w/'runtime'
        if not kit.exists():
            kit.mkdir()
            with tarfile.open(args.runtime_kit) as t:t.extractall(kit,filter='tar')
        if not (kit/'provenance.json').exists() or json.loads((kit/'provenance.json').read_text()).get('vendor_delivery')!='installer-v1':
            raise ValueError('This runtime kit predates installer-provided WLAN; rebuild without --runtime-kit')
        if not (kit/'kernel.config').exists() or not (kit/'system/usr/share/be7000/kmods.json').exists():
            raise ValueError('This runtime kit predates signed kmod packages; rebuild without --runtime-kit')
        if json.loads((kit/'provenance.json').read_text()).get('this_build',{}).get('kernel')!=KERNEL:
            raise ValueError('Runtime kit kernel differs from the pinned source; rebuild without --runtime-kit')
        shutil.copy2(kit/'kernel.config',b/'.config')
    else:
        # Modules are built against an initial kernel without an embedded root;
        # the final Image embeds the freshly assembled rescue environment below.
        run(k/'scripts/config','--file',b/'.config','--set-str','INITRAMFS_SOURCE','')
        kit=bootstrap(w,k,b,cross,args.j)
    stamp(kit/'system',P)
    for name in ['system','initramfs']:
        (kit/name/'mnt/usb').mkdir(parents=True,exist_ok=True)
        shutil.copytree(P/'runtime'/name,kit/name,dirs_exist_ok=True,symlinks=True)
        for f in (P/'runtime'/name).rglob('*'):
            if f.is_file() and f.read_bytes().startswith(b'#!'):(kit/name/f.relative_to(P/'runtime'/name)).chmod(0o755)
    late_cpus=kit/'system/etc/rc.d/S96be7000-cpus'
    if late_cpus.is_symlink() and os.readlink(late_cpus)=='../init.d/be7000-cpus':late_cpus.unlink()
    for name in ['S17be7000-cpus','S19be7000-acceleration','K18be7000-acceleration','S20be7000-swap','K90be7000-swap','S99be7000-boot-confirm','S99be7000-crypto']:
        link=kit/'system/etc/rc.d'/name
        if not link.is_symlink():link.symlink_to('../init.d/'+name[3:])
    # The unused RAM userspace init also must carry no old diagnostic defaults.
    shutil.copy2(kit/'initramfs/init',kit/'system/init')
    # NTFS checkouts may report 0777/0666; never carry those modes into rootfs.
    for name in ['system','initramfs']:
        tree=kit/name
        for f in tree.rglob('*'):
            if f.is_symlink():continue
            if f.is_dir():f.chmod(0o755)
            elif f.is_file():f.chmod(stat.S_IMODE(f.stat().st_mode)&~0o022)
        for rel in ['tmp','rescue/tmp']:
            if (tree/rel).is_dir():(tree/rel).chmod(0o1777)
        for rel in ['root','etc/dropbear','rescue/etc/dropbear']:
            if (tree/rel).is_dir():(tree/rel).chmod(0o700)
        for f in [tree/'etc/shadow',tree/'rescue/etc/shadow',*(tree/'etc/config').glob('*')]:
            if f.is_file():f.chmod(0o600)
    initramfs=w/'initramfs.cpio.gz';cpio(kit/'initramfs',initramfs)
    run(k/'scripts/config','--file',b/'.config','--set-str','INITRAMFS_SOURCE',initramfs,'--module','NFT_QUEUE')
    common=['make','-C',k,'O='+str(b),'ARCH=arm64','CROSS_COMPILE='+cross,'KERNELRELEASE=5.4.164']
    run(*common,'olddefconfig');run(*common,'-j'+str(args.j),'Image','modules_prepare')
    payload=w/'release/payload';payload.mkdir(parents=True,exist_ok=True)
    for name in ['Image','System.map']:
        shutil.copy2(b/('arch/arm64/boot/Image' if name=='Image' else name),payload/name)
    sender=w/'sender'
    shutil.copytree(P/'sender',sender,dirs_exist_ok=True)
    run('python3',P/'tools/generate-handoff-target.py',payload,sender)
    sb=w/'stock-build-r5';sb.mkdir(exist_ok=True)
    if not (sb/'.config').exists():shutil.copy2(P/'configs/stock-sender.config',sb/'.config')
    stockargs=['make','-C',stock,'O='+str(sb),'ARCH=arm64','CROSS_COMPILE='+cross,'KERNELRELEASE=5.4.164']
    run(*stockargs,'olddefconfig','modules_prepare')
    run(*stockargs,'M='+str(sender/'kernel'),'-j'+str(args.j),'modules')
    shutil.copy2(sender/'kernel/kexec_mod.ko',payload/'kexec_mod.ko')
    shutil.copy2(sender/'kernel/arch/arm64/kexec_mod_arm64.ko',payload/'kexec_mod_arm64.ko')
    for name in ['kexec_mod.ko','kexec_mod_arm64.ko']:
        if ('be7000_source_kernels='+','.join(PROFILES)+'\0').encode() not in (payload/name).read_bytes():
            raise ValueError('Sender does not match the installer kernel profiles: '+name)
    if not args.runtime_kit:
        cfg=w/'cfg80211'
        shutil.copytree(k/'net/wireless',cfg,dirs_exist_ok=True)
        run(*common,'M='+str(cfg),'KCFLAGS=-Wno-error=discarded-qualifiers -I'+str(cfg),'-j'+str(args.j),'modules')
        dest=kit/'system/opt/be7000/wlan/modules/cfg80211.ko';shutil.copy2(cfg/'cfg80211.ko',dest)
        run(cross+'strip','--strip-debug',dest)
    vendor_manifest=kit/'system/opt/be7000/wlan/manifest.json'
    vendor_manifest.write_text(json.dumps({'cfg80211':{'origin':'built from source','kernel_commit':KERNEL},
        'other_wifi_modules':'not bundled; copied from the router by the installer'},indent=2)+'\n')
    if not args.runtime_kit:
        package_kmods(w,w/'openwrt',b,kit/'system')
    shutil.copy2(b/'.config',kit/'kernel.config')
    obsolete=kit/'system/opt/be7000/nft/modules'
    if obsolete.exists():shutil.rmtree(obsolete)
    if b'--kernel-base=ADDR' not in (kit/'payload/kexec').read_bytes():
        raise ValueError('Runtime kexec lacks ARM64 kernel-base support; rebuild without --runtime-kit')
    shutil.copy2(kit/'payload/kexec',payload/'kexec');(payload/'kexec').chmod(0o755)
    layout=json.loads((payload/'target-layout.json').read_text())
    for f in (P/'installer').glob('*.sh'):
        data=render_script(f)
        data=data.replace('30822408',str(layout['image_bytes'])).replace('31272960',str(layout['kernel_memsz'])).replace('427321a4',f"{layout['holding_pen']:x}")
        if f.name=='01-load-only.sh':
            needle='FINAL_CMDLINE="console='
            data=data.replace(needle,'''[ -r "$BASE_DIR/launch.conf" ] || die "missing launch.conf"
. "$BASE_DIR/launch.conf"
case "$USB_UUID" in *[!0-9a-fA-F-]*|'') die "invalid USB UUID";; esac
[ "${#USB_UUID}" -eq 36 ] || die "invalid USB UUID length"
case "$DIAGNOSTIC" in 0|1) ;; *) die "invalid diagnostic option";; esac
FINAL_CMDLINE="console=''',1)
            data=data.replace('be7000_source=owrt12"','be7000_source=owrt12 be7000_usb_uuid=$USB_UUID be7000_diagnostic=$DIAGNOSTIC"',1)
        dest=payload/f.name;dest.write_text(data);dest.chmod(0o755);run('sh','-n',dest)
    provenance=json.loads((kit/'provenance.json').read_text()) if (kit/'provenance.json').exists() else {'runtime':'prebuilt input; original build provenance is unavailable'}
    provenance['this_build']={'kernel':KERNEL,'sender_abi':STOCK,'supported_kernels':PROFILES,
                              'cfg80211':KERNEL,'runtime_mode':'prebuilt-kit' if args.runtime_kit else 'source'}
    for target in [kit/'provenance.json',kit/'system/usr/share/be7000/provenance.json',w/'release/provenance.json']:
        target.parent.mkdir(parents=True,exist_ok=True);target.write_text(json.dumps(provenance,indent=2)+'\n')
    user=w/'userdata-root';user.mkdir(exist_ok=True)
    for d in ['upper','work']:(user/d).mkdir(exist_ok=True)
    (user/'base-id').write_text((kit/'system/etc/be7000-system-id').read_text())
    for name,tree,size in [('system',kit/'system',512*1024**2),('userdata',user,2*1024**3)]:
        image=w/(name+'.img')
        with image.open('wb') as f:f.truncate(size)
        run('mke2fs','-q','-t','ext4','-F','-b','4096','-m','0','-O','^orphan_file,^metadata_csum_seed','-E','lazy_itable_init=0,lazy_journal_init=0','-L','be7000-'+name,'-d',tree,image)
        run('e2fsck','-fn',image)
        with image.open('rb') as src,gzip.open(w/'release'/(name+'.img.gz'),'wb',compresslevel=1) as dst:shutil.copyfileobj(src,dst,1024*1024)
    release=w/'release'
    (release/'BOOT_CONTROL_V1').write_text('1\n')
    (release/'manifest.json').write_text(json.dumps({'version':VERSION,'kernel_commit':KERNEL,'stock_abi_commit':STOCK,'supported_kernels':list(PROFILES),
        'runtime':'OpenWrt 25.12.5, QSDK 5.4.164','diagnostic_default':False,'vendor_delivery':'installer-v1',
        'files':{str(f.relative_to(release)):f.stat().st_size for f in release.rglob('*') if f.is_file() and f.name!='manifest.json'}},indent=2))
    with tarfile.open(w/f'BE7000-OpenWrt-{VERSION}.tar.gz','w:gz') as t:
        for f in release.iterdir():t.add(f,arcname=f.name)
    with tarfile.open(w/f'BE7000-runtime-{VERSION}.tar.gz','w:gz') as t:
        for f in kit.iterdir():t.add(f,arcname=f.name)
    fwtool=w/'openwrt/staging_dir/host/bin/fwtool'
    if not fwtool.is_file():
        # Runtime-kit builds also need the small upstream image-metadata tool.
        toolsrc=w/'fwtool-source'
        if not toolsrc.exists():
            run('git','clone','https://git.openwrt.org/project/fwtool.git',toolsrc)
        run('git','-C',toolsrc,'checkout','--detach','04cd252e4e9394ffacd51f56f1f124abc534f715')
        fwtool=toolsrc/'fwtool'
        run('cc','-O2','-o',fwtool,toolsrc/'fwtool.c')
    print('Sysupgrade image:',package_sysupgrade(release,w/f'BE7000-OpenWrt-{VERSION}-sysupgrade.bin',fwtool,VERSION))
    print('Release bundle:',w/f'BE7000-OpenWrt-{VERSION}.tar.gz')
    print('Runtime archive:',w/f'BE7000-runtime-{VERSION}.tar.gz')

if __name__=='__main__':main()
