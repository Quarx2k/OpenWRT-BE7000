"""Source preparation and runtime build for BE7000 (Linux only)."""
from pathlib import Path
import argparse, json, os, re, shutil, subprocess, tarfile, urllib.request
from build_acceleration import build as build_acceleration
from build_kmods import configure as configure_kmods

P=Path(__file__).resolve().parents[1]
LOCK=json.loads((P/'sources.lock.json').read_text())
LINUX_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

def run(*args, cwd=None):
    subprocess.run(list(map(str,args)),cwd=cwd,check=True,
                   env={**os.environ,'PATH':LINUX_PATH,'FORCE_UNSAFE_CONFIGURE':'1'})

def checkout(work,name):
    entry=LOCK[name];tree=work/name
    if not (tree/'.git').exists():
        tree.mkdir(parents=True,exist_ok=True)
        run('git','init',tree)
        run('git','-C',tree,'remote','add','origin',entry['url'])
        run('git','-C',tree,'fetch','--depth=1','origin',entry['revision'])
        run('git','-C',tree,'checkout','--detach','FETCH_HEAD')
    actual=subprocess.check_output(['git','-C',str(tree),'rev-parse','HEAD'],text=True).strip()
    if actual!=entry['revision']:raise ValueError(f'{name}: unexpected source revision {actual}')
    if entry.get('patch'):
        patch=P/entry['patch']
        applied=subprocess.run(['git','-C',str(tree),'apply','--reverse','--check',str(patch)],capture_output=True)
        if applied.returncode:run('git','-C',tree,'apply',patch)
    return tree

def userspace(work,jobs):
    tree=checkout(work,'openwrt')
    shutil.copytree(P/'packages/be7000-wifi',tree/'package/be7000-wifi',dirs_exist_ok=True)
    # The release tag pins feed revisions in feeds.conf.default.
    if not (tree/'feeds/luci/luci.mk').exists():
        run('./scripts/feeds','update','packages','luci',cwd=tree)
    for feed in ['packages','luci']:
        run('./scripts/feeds','install','-a','-p',feed,cwd=tree)
    for name in ['999-be7000-data-netdev.patch','999-be7000-txpower-list.patch']:
        (tree/'package/network/utils/iwinfo/patches'/name).unlink(missing_ok=True)
    if not (tree/'.config').exists():shutil.copy2(P/'configs/openwrt.config',tree/'.config')
    config=(tree/'.config').read_text()
    # Apply the maintained seed to incremental builds as well as fresh builds.
    for line in (P/'configs/openwrt.config').read_text().splitlines():
        match=re.match(r'(?:# )?(CONFIG_[\w-]+)(?:=| is not set)',line)
        if match:
            option=re.escape(match[1])
            config=re.sub(r'^(?:'+option+r'=.*|# '+option+r' is not set)\n','',config,flags=re.M)
            config+=line+'\n'
    for option in ['PACKAGE_u-boot-qemu_armv8','TARGET_ROOTFS_INITRAMFS','TARGET_ROOTFS_CPIOGZ']:
        config=re.sub(r'^(?:CONFIG_'+option+r'=.*|# CONFIG_'+option+r' is not set)\n','',config,flags=re.M)
        config+='# CONFIG_'+option+' is not set\n'
    config=re.sub(r'^(?:CONFIG_PACKAGE_be7000-wifi=.*|# CONFIG_PACKAGE_be7000-wifi is not set)\n','',config,flags=re.M)
    for option in ['PACKAGE_hostapd-basic-mbedtls','PACKAGE_wpad-mbedtls']:
        config=re.sub(r'^(?:CONFIG_'+option+r'=.*|# CONFIG_'+option+r' is not set)\n','',config,flags=re.M)
    config+='# CONFIG_PACKAGE_hostapd-basic-mbedtls is not set\nCONFIG_PACKAGE_wpad-mbedtls=y\n'
    config=re.sub(r'^(?:CONFIG_PACKAGE_losetup=.*|# CONFIG_PACKAGE_losetup is not set)\n','',config,flags=re.M)
    (tree/'.config').write_text(config+'CONFIG_PACKAGE_be7000-wifi=y\nCONFIG_PACKAGE_losetup=y\n')
    run('make','defconfig',cwd=tree)
    for mode in ['11AC','11AX','11BE']:
        if f'CONFIG_DRIVER_{mode}_SUPPORT=y' not in (tree/'.config').read_text():
            raise ValueError(f'BE7000 hostapd requires {mode} support')
    run('make','-j'+str(jobs),'download',cwd=tree)
    run('make','-j'+str(jobs),cwd=tree)
    return tree

def copy(src,dest):
    dest.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(src,dest)

def archive_source(work,name,url):
    tree=work/name
    if not tree.exists():
        archive=work/Path(url).name
        if not archive.exists():
            cached=work/'openwrt/dl'/archive.name
            if cached.is_file():shutil.copy2(cached,archive)
            else:urllib.request.urlretrieve(url,archive)
        with tarfile.open(archive) as t:t.extractall(work,filter='data')
    return tree

def modules(work,k,b,cross,jobs):
    """Compile every open kernel module included in the runtime."""
    sources={name:checkout(work,name) for name in ['ssdk','ppe','dp','nat46','amneziawg','wireguard']}
    common=['make','-C',k,'O='+str(b),'ARCH=arm64','CROSS_COMPILE='+cross,'KERNELRELEASE=5.4.164','-j'+str(jobs)]
    requested=dict(re.findall(r'^CONFIG_(\w+)=(y|m|n)$',(P/'configs/netfilter.config').read_text(),re.M))
    for option,value in requested.items():
        run(k/'scripts/config','--file',b/'.config',{'y':'--enable','m':'--module','n':'--disable'}[value],option)
    run(k/'scripts/config','--file',b/'.config','--module','NF_TABLES_SET','--module','NFT_FIB_IPV4','--module','NFT_FIB_IPV6','--module','NFT_FIB_INET','--module','NFT_QUEUE')
    run(*common,'olddefconfig')
    config=dict(re.findall(r'^CONFIG_(\w+)=(.+)$',(b/'.config').read_text(),re.M))
    missing=[name for name,value in requested.items() if config.get(name,'n')!=value]
    if missing:raise ValueError('Unavailable netfilter options: '+', '.join(missing))
    if config.get('NETWORK_SECMARK')=='y':raise ValueError('SECMARK changes the vendor sk_buff ABI')
    packaged=configure_kmods(work/'openwrt',k,b,common)
    config=dict(re.findall(r'^CONFIG_(\w+)=(.+)$',(b/'.config').read_text(),re.M))
    targets=[]
    for folder in ['net/netfilter','net/netfilter/ipset','net/ipv4/netfilter','net/ipv6/netfilter','net/bridge/netfilter']:
        for option,objects in re.findall(r'^obj-\$\(CONFIG_(\w+)\)\s*\+=\s*(.+)$',(k/folder/'Makefile').read_text(),re.M):
            if config.get(option)=='m':
                targets.extend(folder+'/'+obj[:-2]+'.ko' for obj in objects.split() if obj.endswith('.o'))
    targets=sorted(set(targets))
    targets+=['drivers/net/tun.ko','net/ipv4/inet_diag.ko','net/ipv4/tcp_diag.ko','net/ipv4/udp_diag.ko','net/unix/unix_diag.ko']
    usb=['drivers/usb/host/xhci-hcd.ko','drivers/usb/host/xhci-plat-hcd.ko','drivers/usb/dwc3/dwc3.ko','drivers/usb/dwc3/dwc3-qcom.ko','drivers/usb/storage/usb-storage.ko']
    leds=['drivers/leds/leds-gpio.ko']
    # configure_kmods built the complete configured module set in one MODPOST pass.
    built=sorted(set(packaged+[b/t for t in targets+usb+leds]))
    ssdk,ppe,dp,nat,awg=[sources[n] for n in ['ssdk','ppe','dp','nat46','amneziawg']]
    # SSDK's parallel make does not order dependency files after build_dir.
    # Prepare both output directories before its recursive jobs start.
    for folder in ['build/linux/KSLIB','build/bin']:
        (ssdk/folder).mkdir(parents=True,exist_ok=True)
    run('env','PATH='+str(Path(cross).parent)+':'+LINUX_PATH,'make','-C',ssdk,'-j'+str(jobs),'ARCH=arm64','KVER=5.4.164','KERNELRELEASE=5.4.164',
        'SYS_PATH='+str(b),'KERNEL_SRC='+str(k),'TOOL_PATH='+str(Path(cross).parent),'TOOLPREFIX='+Path(cross).name,
        'TARGET_NAME=aarch64-linux','GCC_VERSION=7.5.0','CPU=arm64','CHIP_TYPE=APPE','SWCONFIG_FEATURE=enable',
        'UK_NL_PROT=31','EXTRA_CFLAGS=-I'+str(k/'arch/arm64/include/uapi')+' -nostdinc -mgeneral-regs-only')
    built.append(ssdk/'build/bin/qca-ssdk.ko')
    headers=work/'include/nat46';headers.mkdir(parents=True,exist_ok=True)
    for h in (nat/'nat46/modules').glob('*.h'):copy(h,headers/h.name)
    inc=[ssdk/'include',ssdk/'include/init',ssdk/'include/fal',ssdk/'include/common',ssdk/'include/sal/os',
         ssdk/'include/sal/os/linux',ppe/'exports',ppe/'drv/exports',ppe/'drv/ppe_drv',work/'include']
    flags=' '.join('-I'+str(x) for x in inc)
    symbols=[ssdk/'Module.symvers']
    for tree,extra in [(nat/'nat46/modules',' -DNAT46_VERSION=\\"1182f30-qsdk-r5\\"'),(ppe/'drv/ppe_drv',''),(dp,' -DNSS_DP_POINT_OFFLOAD')]:
        if tree==dp:copy(dp/'hal/soc_ops/ipq95xx/nss_ipq95xx.h',dp/'exports/nss_dp_arch.h')
        run(*common,'M='+str(tree),'SoC=ipq95xx','EXTRA_CFLAGS='+flags+extra,'KBUILD_EXTRA_SYMBOLS='+' '.join(map(str,symbols)),'modules')
        symbols.append(tree/'Module.symvers');built.extend(tree.glob('*.ko'))
    deps=work/'udp-tunnels';deps.mkdir(exist_ok=True)
    for rel in ['net/ipv4/udp_tunnel.c','net/ipv6/ip6_udp_tunnel.c']:copy(k/rel,deps/Path(rel).name)
    (deps/'Makefile').write_text('obj-m := udp_tunnel.o ip6_udp_tunnel.o\n')
    run(*common,'M='+str(deps),'modules')
    run(*common,'M='+str(awg/'src'),'KBUILD_EXTRA_SYMBOLS='+str(deps/'Module.symvers'),'WIREGUARD_VERSION=2.0.20260725','modules')
    run(*common,'M='+str(sources['wireguard']/'src'),'KBUILD_EXTRA_SYMBOLS='+str(deps/'Module.symvers'),'modules')
    built.extend([deps/'udp_tunnel.ko',deps/'ip6_udp_tunnel.ko',awg/'src/amneziawg.ko'])
    built.append(sources['wireguard']/'src/wireguard.ko')
    symbols.append(deps/'Module.symvers')
    built.extend(build_acceleration(work,k,common,symbols,inc,checkout,run))
    return built

def static_tools(work,jobs):
    busy=archive_source(work,'busybox-1.37.0','https://busybox.net/downloads/busybox-1.37.0.tar.bz2')
    if not (busy/'.config').exists():copy(P/'configs/rescue-busybox.config',busy/'.config')
    run('make','-C',busy,'CROSS_COMPILE=aarch64-linux-gnu-','-j'+str(jobs))
    for name in ['netguard','kmsg-log']:
        run('aarch64-linux-gnu-gcc','-Os','-static','-s',P/'runtime/src'/(name+'.c'),'-o',work/name)
    kexec=archive_source(work,'kexec-tools-2.0.32','https://mirrors.edge.kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-2.0.32.tar.xz')
    for name in ['kexec-tools.patch','kexec-tools-arm64-kernel-base.patch']:
        patch=P/'patches/userspace'/name
        applied=subprocess.run(['patch','--dry-run','-R','-p1','-i',str(patch)],cwd=kexec,capture_output=True)
        if applied.returncode:run('patch','-p1','-i',patch,cwd=kexec)
    kb=work/'kexec-build';kb.mkdir(exist_ok=True)
    if not (kb/'Makefile').exists():
        run(kexec/'configure','--host=aarch64-linux-gnu','--without-zlib','--without-lzma','--without-zstd','--without-xen',
            'CC=aarch64-linux-gnu-gcc','CPPFLAGS=-I'+str(kb/'include'),'CFLAGS=-Os -fno-ident','LDFLAGS=-static',cwd=kb)
    run('make','-j'+str(jobs),'build/sbin/kexec',cwd=kb)
    if b'--kernel-base=ADDR' not in (kb/'build/sbin/kexec').read_bytes():
        raise ValueError('Built kexec lacks the required ARM64 kernel-base support')
    return busy/'busybox',kb/'build/sbin/kexec'

def copy_elf(root,dest,name,copied=None):
    """Copy a program with its ELF interpreter and shared-library closure."""
    copied=set() if copied is None else copied
    name=name.lstrip('/')
    if name in copied:return
    copied.add(name);src=root/name
    if src.is_symlink():
        link=os.readlink(src)
        target=link.lstrip('/') if link.startswith('/') else os.path.normpath(str(Path(name).parent/link))
        copy_elf(root,dest,target,copied)
        out=dest/name;out.parent.mkdir(parents=True,exist_ok=True);out.symlink_to(link)
        return
    copy(src,dest/name)
    info=subprocess.check_output(['readelf','-lW','-dW',str(src)],text=True)
    interp=re.search(r'Requesting program interpreter: ([^\]]+)',info)
    if interp:copy_elf(root,dest,interp[1],copied)
    for lib in re.findall(r'\(NEEDED\).*\[([^\]]+)\]',info):
        rel=next((d+'/'+lib for d in ['lib','usr/lib'] if (root/d/lib).exists() or (root/d/lib).is_symlink()),None)
        if rel is None:raise ValueError(f'{name}: missing library {lib}')
        copy_elf(root,dest,rel,copied)

def assemble(work,owrt,built,busy,kexec):
    kit=work/'runtime-source'
    if kit.exists():shutil.rmtree(kit)
    system=kit/'system';system.mkdir(parents=True)
    archives=list((owrt/'bin/targets/armsr/armv8').glob('*-generic-rootfs.tar.gz'))
    if len(archives)!=1:raise ValueError('Expected one OpenWrt rootfs archive')
    with tarfile.open(archives[0]) as t:t.extractall(system,filter='tar')
    # The generic armsr kernel is only a build dependency. BE7000 uses QSDK.
    for rel in ['lib/modules','etc/modules.d','etc/modules-boot.d']:
        path=system/rel
        if path.exists():shutil.rmtree(path)
        path.mkdir(parents=True)
    (system/'opt/be7000/wlan/modules').mkdir(parents=True)
    copy(system/'lib/firmware/regulatory.db',system/'opt/be7000/wlan/regulatory.db')
    shutil.rmtree(system/'lib/firmware');(system/'lib/firmware').symlink_to('/opt/be7000/vendor/firmware')
    (system/'ini').symlink_to('/opt/be7000/vendor/ini')
    for rel in ['rom','overlay','rescue','mnt/usb','opt/be7000/calibration','opt/be7000/vendor']:(system/rel).mkdir(parents=True,exist_ok=True)
    ram=kit/'initramfs';rescue=ram/'rescue'
    for rel in ['bin','sbin','etc/dropbear','root','lib','usr/sbin','dev/pts','proc','sys','tmp','run']:(rescue/rel).mkdir(parents=True,exist_ok=True)
    copy(busy,rescue/'bin/busybox')
    applets=subprocess.check_output(['qemu-aarch64-static',str(busy),'--list'],text=True).splitlines()
    for applet in applets:
        if applet!='busybox':(rescue/'bin'/applet).symlink_to('busybox')
    for name in ['netguard','kmsg-log']:copy(work/name,rescue/'bin'/name)
    copied=set()
    copy_elf(system,rescue,'usr/sbin/dropbear',copied)
    copy_elf(system,rescue,'usr/sbin/e2fsck',copied)
    for name in ['passwd','group','shadow','shells']:copy(system/'etc'/name,rescue/'etc'/name)
    shadow=rescue/'etc/shadow';shadow.write_text(re.sub(r'^root:[^:]*:', 'root:!:',shadow.read_text(),flags=re.M))
    for rel in ['dev/pts','proc','sys','tmp','run','mnt','lib/modules/5.4.164']:(ram/rel).mkdir(parents=True,exist_ok=True)
    (ram/'bin').symlink_to('rescue/bin')
    for module in built:
        copy(module,system/'lib/modules/5.4.164'/module.name)
        run('aarch64-linux-gnu-strip','--strip-debug',system/'lib/modules/5.4.164'/module.name)
        if module.stem in ['qca-ssdk','nf_defrag_ipv6','nat46','qca-nss-ppe','qca-nss-dp','xhci-hcd','xhci-plat-hcd','dwc3','dwc3-qcom','usb-storage','leds-gpio']:
            copy(system/'lib/modules/5.4.164'/module.name,ram/'lib/modules/5.4.164'/module.name)
    (system/'etc/modules.d/90-amneziawg').write_text('udp_tunnel\nip6_udp_tunnel\namneziawg\n')
    (system/'etc/modules.d/30-tun').write_text('tun\n')
    # Configs and board support are maintained in main, not copied from a router.
    for name in ['system','initramfs']:shutil.copytree(P/'runtime'/name,kit/name,dirs_exist_ok=True,symlinks=True)
    for po in (P/'translations').glob('*/*.po'):
        dest=system/'usr/lib/lua/luci/i18n'/f'{po.stem}.{po.parent.name}.lmo'
        dest.parent.mkdir(parents=True,exist_ok=True)
        run(owrt/'staging_dir/hostpkg/bin/po2lmo',po,dest)
    for name,start in [('be7000-platform','18'),('be7000-acceleration','19'),('be7000-cpus','17'),('be7000-swap','20'),('be7000-boot-confirm','99')]:
        (system/'etc/rc.d'/('S'+start+name)).symlink_to('../init.d/'+name)
    (system/'etc/rc.d/K18be7000-acceleration').symlink_to('../init.d/be7000-acceleration')
    (system/'etc/inittab').write_text('::sysinit:/etc/init.d/rcS S boot\n::shutdown:/etc/init.d/rcS K shutdown\nttyMSM0::askfirst:/usr/libexec/login.sh\n')
    copy(kexec,kit/'payload/kexec')
    tools=checkout(work,'amneziawg-tools')
    compiler=next((owrt/'staging_dir').glob('toolchain-aarch64*/bin/aarch64-openwrt-linux-musl-gcc'))
    run('make','-C',tools/'src','CC='+str(compiler),'WITH_BASHCOMPLETION=no','WITH_WGQUICK=no','-j4')
    copy(tools/'src/wg',system/'usr/bin/awg')
    provenance={'sources':LOCK,'built_from_source':['OpenWrt userspace','iwinfo','QSDK kernel','cfg80211','kexec sender','kexec-tools 2.0.32','BusyBox 1.37.0','AmneziaWG tools','netguard','kmsg-log']+[p.name for p in built],
        'vendor_binaries':{'included':False,'delivery':'installer copies WLAN modules and firmware from the router'},'calibration':'Not included; copied from each router by installer'}
    provenance['vendor_delivery']='installer-v1'
    provenance['openwrt_feeds']=(owrt/'feeds.conf.default').read_text().splitlines()
    copy(owrt/'.config',kit/'openwrt.config')
    (kit/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    return kit

def bootstrap(work,k,b,cross,jobs):
    owrt=userspace(work,jobs)
    built=modules(work,k,b,cross,jobs)
    busy,kexec=static_tools(work,jobs)
    return assemble(work,owrt,built,busy,kexec)

if __name__=='__main__':
    a=argparse.ArgumentParser(description=__doc__)
    a.add_argument('--work',type=Path,required=True);a.add_argument('-j',type=int,default=16)
    args=a.parse_args()
    if str(args.work.resolve()).startswith('/mnt/'):raise ValueError('Use a Linux filesystem')
    userspace(args.work.resolve(),args.j)
