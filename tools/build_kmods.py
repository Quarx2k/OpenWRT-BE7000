"""Package the QSDK kernel and OpenWrt kmods in a signed, local APK repository."""
from pathlib import Path
import json, re, shutil, subprocess, uuid
import sys

P=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(P/'installer'))
from wlan import MODULES as VENDOR_MODULES
VERSION='5.4.164'
REPO_PATH='usr/share/be7000/packages'
EXCLUDED={'kmod-nfnetlink-cttimeout': 'QSDK conntrack already uses all nine extension slots'}
EXTRA='''tun ppp ppp-synctty pppoe pppol2tp pppox mppe pptp l2tp l2tp-eth l2tp-ip
gre gre6 ipip sit ip6-tunnel ip-vti ip6-vti ipsec ipsec4 ipsec6 xfrm-interface
udptunnel4 udptunnel6 fs-cifs fs-nfs fs-nfs-v3 fs-nfs-v4 fs-nfsd fs-nfs-common-rpcsec
nls-utf8 nls-cp437 nls-iso8859-1 crypto-gcm crypto-sha256 crypto-sha512
crypto-chacha20poly1305 inet-diag unix-diag'''.split()


def run(*args, **kwargs):
    return subprocess.run(list(map(str,args)),check=True,**kwargs)


def config(path):
    return dict(re.findall(r'^CONFIG_(\w+)=(.+)$',path.read_text(),re.M))


def metadata(owrt,b):
    out=b.parent/'kmod-metadata.txt'
    run('make','-s','-f',P/'tools/kmod-metadata.mk','OPENWRT='+str(owrt),
        'KERNEL_BUILD='+str(b),'OUTPUT='+str(out))
    packages={}
    for block in out.read_text().split('End:'):
        d=dict(line.split(': ',1) for line in block.strip().splitlines() if ': ' in line)
        if 'Name' not in d:continue
        d['files']=[str(Path(f).relative_to(b)) for f in d.get('Files','').split()]
        d['config']=d.get('Kconfig','').split()
        deps=[]
        for token in d.get('Depends','').split():
            if token.startswith('@'):continue
            token=token.lstrip('+')
            deps.append(token)
        d['deps']=sorted(set(deps));packages[d['Name']]=d
    # These definitions describe the same functions before their 6.x moves.
    cifs=packages['kmod-fs-cifs']
    cifs['files']=['fs/cifs/cifs.ko']
    cifs['deps'].remove('kmod-fs-smbfs-common')
    cifs['deps']+=['kmod-crypto-md4','kmod-crypto-arc4']
    packages['kmod-fs-nfs-v3']['config']+=['CONFIG_NFS_V3=y','CONFIG_NFS_V3_ACL=y']
    packages['kmod-fs-nfs-v4']['config']+=['CONFIG_PNFS_FILE_LAYOUT=m','CONFIG_PNFS_FLEXFILE_LAYOUT=m']
    packages['kmod-fs-nfsd']['config']+=['CONFIG_NFSD_V3=y','CONFIG_NFSD_V3_ACL=y']
    packages['kmod-fs-nfs-common']['files']+=['fs/nfs_common/nfs_acl.ko']
    packages['kmod-nft-arp']['config']+=['CONFIG_NF_TABLES_ARP=y']
    packages['kmod-nft-bridge']['config']+=['CONFIG_NF_TABLES_BRIDGE=m']
    packages['kmod-nf-flow']['files']+=['net/netfilter/nf_flow_table_hw.ko']
    # 5.4 exports the IPv6 UDP tunnel helpers from the IPv6 core.
    packages['kmod-udptunnel6']['config']+=['CONFIG_IPV6=y']
    packages['kmod-arptables']['files']=['net/ipv4/netfilter/'+n+'.ko' for n in ['arp_tables','arptable_filter','arpt_mangle']]
    packages['kmod-crypto-gf128']['files']=['crypto/gf128mul.ko']
    packages['kmod-crypto-authenc']['config']+=['CONFIG_CRYPTO_AUTHENC_ESN=m']
    # Shared IV helpers live in aead.ko in 5.4; seqiv has its own package.
    packages['kmod-crypto-geniv']['files']=[]
    packages['kmod-crypto-geniv']['config']=['CONFIG_CRYPTO_AEAD2']
    # QSDK's DRBG uses SHA1/SHA256 too. Its registration tests need the hash
    # algorithms loaded already, before the default priority-09 DRBG module.
    packages['kmod-crypto-rng']['deps']+=['kmod-crypto-sha1','kmod-crypto-sha256']
    for name in ['hmac','sha1','sha256','sha512']:
        d=packages['kmod-crypto-'+name]
        d['Autoload']='08 '+d['Autoload'].split(' ',1)[1]
    # Package the generic algorithms; do not assume optional ARM crypto extensions.
    for d in packages.values():
        d['files']=[f for f in d['files'] if not f.startswith('arch/arm64/crypto/')]
        d['config']=[v for v in d['config'] if not (v.startswith('CONFIG_CRYPTO_') and
            re.search(r'_(ARM|PPC|OCTEON|SSSE3|AVX|S390|MIPS)',v))]
    return packages


def selection(owrt,packages):
    text=(owrt/'package/kernel/linux/modules/netfilter.mk').read_text()
    names={'kmod-'+n for n in re.findall(r'^define KernelPackage/([a-z0-9][a-z0-9_+-]*)$',text,re.M)}
    names.update('kmod-'+n for n in EXTRA);names.difference_update(EXCLUDED)
    todo=list(names)
    while todo:
        name=todo.pop()
        if name not in packages:raise ValueError('No OpenWrt definition for '+name)
        resolved=[]
        for dep in packages[name]['deps']:
            if ':' in dep:
                condition,dep=dep.split(':',1)
                if condition!='IPV6':raise ValueError(f'Unresolved dependency: {name} {condition}')
            resolved.append(dep)
            if dep.startswith('kmod-') and dep not in names:
                names.add(dep);todo.append(dep)
        packages[name]['deps']=resolved
    return {n:packages[n] for n in sorted(names)}


def configure(owrt,k,b,common):
    packages=selection(owrt,metadata(owrt,b))
    types={}
    for path in k.rglob('Kconfig*'):
        if not path.is_file():continue
        for block in re.split(r'^\s*(?:menu)?config\s+',Path(path).read_text(errors='replace'),flags=re.M)[1:]:
            name=block.split()[0]
            m=re.search(r'^\s*(bool|tristate|int|hex|string)\b',block,re.M)
            if m:types[name]=m[1]
    wanted={}
    for d in packages.values():
        for value in d['config']:
            name,sep,value=value.removeprefix('CONFIG_').partition('=')
            if name not in types:continue # renamed/removed alternatives in upstream recipes
            if not sep:value='y' if types[name]=='bool' else 'm'
            if name in ['NFS_V3','NFS_V4']:value='m' # tristates in 5.4, booleans in current OpenWrt
            if value=='n':continue # another selected package may enable this option
            if wanted.get(name)!='y':wanted[name]=value
    # Preserve the vendor ABI and the QSDK conntrack extension limit.
    wanted.update(NETWORK_SECMARK='n',NF_CONNTRACK_TIMEOUT='n',NF_CONNTRACK_TIMESTAMP='n',NF_CT_NETLINK_TIMEOUT='n',BOOTCONFIG_PARTITION='n')
    data=(b/'.config').read_text()
    for name,value in wanted.items():
        data=re.sub(r'^(?:CONFIG_'+name+r'=.*|# CONFIG_'+name+r' is not set)\n','',data,flags=re.M)
        data+=('CONFIG_'+name+'='+value if value!='n' else '# CONFIG_'+name+' is not set')+'\n'
    (b/'.config').write_text(data)
    run(*common,'olddefconfig')
    actual=config(b/'.config')
    # Built-in consumers can select a shared helper as y even when its package
    # requests m. Keep that Kconfig dependency, not every built-in QSDK default.
    builtin_deps={n for n,v in wanted.items() if v=='m' and actual.get(n)=='y'}
    missing={n:v for n,v in wanted.items() if actual.get(n,'n')!=v and n not in builtin_deps}
    if missing:raise ValueError('Unavailable requested kmod settings: '+str(missing))
    run(*common,'Image','modules_prepare','modules.builtin')
    packages=selection(owrt,metadata(owrt,b))
    builtin=set((b/'modules.builtin').read_text().splitlines())
    targets=sorted({f for d in packages.values() for f in d['files'] if f not in builtin})
    (b.parent/'kmod-plan.json').write_text(json.dumps({'packages':packages,'targets':targets,'excluded':EXCLUDED,
        'config_symbols':sorted(types),'builtin_dependencies':sorted(builtin_deps)},indent=2)+'\n')
    print(f'Kmod plan: {len(packages)} packages, {len(targets)} module targets',flush=True)
    run(*common,'KCFLAGS=-I'+str(k/'net/netfilter'),'modules')
    missing=[f for f in targets if not (b/f).exists()]
    if missing:raise ValueError('Missing packaged modules: '+', '.join(missing))
    # Kconfig may select helpers not split out in the 6.x package definitions.
    available={}
    for f in (b/'modules.order').read_text().splitlines():
        path=b/f.removeprefix('kernel/')
        name,deps=module_info(path);available[name]=(path,deps)
    built={b/f for f in targets};todo=list(built)
    builtin_names={Path(f).stem.replace('-','_') for f in builtin}
    while todo:
        _,deps=module_info(todo.pop())
        for name in filter(None,deps):
            if name in builtin_names:continue
            if name not in available:raise ValueError('Unbuilt module dependency '+name)
            path,_=available[name]
            if path not in built:built.add(path);todo.append(path)
    return sorted(built)


def module_info(path):
    data=subprocess.check_output(['modinfo',str(path)],text=True)
    fields=dict(line.split(':',1) for line in data.splitlines() if ':' in line)
    return fields['name'].strip().replace('-','_'),[n.replace('-','_') for n in fields.get('depends','').strip().split(',')]


def installed(root):
    result={}
    for block in (root/'lib/apk/db/installed').read_text().split('\n\n'):
        name=re.search(r'^P:(.+)$',block,re.M)
        if name:result[name[1]]=block
    return result


def package(work,owrt,b,system):
    """Create real packages, replace generic kernel metadata, install the base set."""
    apk=owrt/'staging_dir/host/bin/apk'
    plan=json.loads((work/'kmod-plan.json').read_text())
    packages=plan['packages']
    builtin=set((b/'modules.builtin').read_text().splitlines())
    builtin_names={Path(f).stem.replace('-','_') for f in builtin}
    abi=VERSION+'~be7000'+uuid.uuid4().hex+'-r1'
    output=work/'kmod-repository'
    stages=work/'kmod-package-roots'
    for directory in [output,stages]:
        if directory.exists():shutil.rmtree(directory)
        directory.mkdir()
    signing=work/'apk-signing';signing.mkdir(mode=0o700,exist_ok=True)
    private=signing/'be7000.pem';public=signing/'be7000.pub'
    if not private.exists():
        private.touch(mode=0o600)
        run('openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:3072','-out',private,stderr=subprocess.DEVNULL)
    private.chmod(0o600)
    run('openssl','pkey','-in',private,'-pubout','-out',public)
    kernels=system/'lib/modules'/VERSION
    owners={};extra_deps={}

    def put(name,source,relative):
        dest=stages/name/relative;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,dest)
        if dest.suffix=='.ko':
            run('aarch64-linux-gnu-strip','--strip-debug',dest)
            mod,deps=module_info(dest)
            if mod in owners and owners[mod]!=name:raise ValueError(f'Duplicate module {mod}: {name}, {owners[mod]}')
            owners[mod]=name;extra_deps.setdefault(name,set()).update(filter(None,deps))

    for name,d in packages.items():
        (stages/name).mkdir()
        for f in d['files']:
            if f not in builtin:put(name,b/f,'lib/modules/'+VERSION+'/'+Path(f).name)
        if name=='kmod-br-netfilter':
            put(name,owrt/'package/kernel/linux/files/sysctl-br-netfilter.conf','etc/sysctl.d/11-br-netfilter.conf')
    for name,filename in [('kmod-wireguard','wireguard.ko'),('kmod-amneziawg','amneziawg.ko')]:
        packages[name]={'Title':filename.removesuffix('.ko'),'deps':['kmod-udptunnel4','kmod-udptunnel6'],'Autoload':'0 0 '+filename.removesuffix('.ko'),'config':[]}
        put(name,kernels/filename,'lib/modules/'+VERSION+'/'+filename)
    name='kmod-cfg80211'
    packages[name]={'Title':'BE7000 cfg80211 (built from QSDK sources)','deps':[],'config':[]}
    put(name,system/'opt/be7000/wlan/modules/cfg80211.ko','opt/be7000/wlan/modules/cfg80211.ko')
    name='kmod-be7000-platform'
    packages[name]={'Title':'BE7000 Ethernet, USB and hardware acceleration','deps':[],'config':[]}
    (stages/name).mkdir()
    for module in sorted(kernels.glob('*.ko')):
        mod,_=module_info(module)
        if mod not in owners and mod not in builtin_names:put(name,module,'lib/modules/'+VERSION+'/'+module.name)
    # Resolve implicit .ko dependencies as well as OpenWrt's package dependencies.
    for name,deps in extra_deps.items():
        for mod in deps:
            if mod in builtin_names:continue
            if mod in VENDOR_MODULES:
                packages[name].setdefault('vendor_modules',[]).append(mod)
                continue
            if mod not in owners:raise ValueError(f'{name}: unpackaged module dependency {mod}')
            if owners[mod]!=name:packages[name]['deps'].append(owners[mod])
    packages['kernel']={'Title':'BE7000 QSDK '+VERSION,'deps':['libc'],'config':[]}
    dest=stages/'kernel/lib/modules'/VERSION;dest.mkdir(parents=True)
    (dest/'modules.builtin').write_text(''.join(f+'\n' for f in sorted({Path(f).name for f in builtin})))
    shutil.copy2(b/'modules.builtin.modinfo',dest/'modules.builtin.modinfo')
    (stages/'kernel/etc').mkdir()
    (stages/'kernel/etc/be7000-kernel-abi').write_text(abi+'\n')
    post=work/'kmod-post-install.sh'
    post.write_text('#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || /sbin/kmodloader\nexit 0\n');post.chmod(0o755)
    archives=[]
    for name,d in sorted(packages.items()):
        stage=stages/name
        auto=d.get('Autoload','').split()
        if len(auto)>2:
            mods=[m for m in auto[2:] if m.replace('-','_') in owners]
            if mods:
                modules=stage/'etc/modules.d';modules.mkdir(parents=True,exist_ok=True)
                filename=(auto[0]+'-' if auto[0]!='0' else '')+name.removeprefix('kmod-')
                (modules/filename).write_text('\n'.join(m+(' '+d['Params'] if d.get('Params') else '') for m in mods)+'\n')
                if auto[1]=='1':
                    boot=stage/'etc/modules-boot.d';boot.mkdir(parents=True,exist_ok=True)
                    (boot/filename).symlink_to('../modules.d/'+filename)
        listing=stage/'lib/apk/packages'/(name+'.list')
        listing.parent.mkdir(parents=True,exist_ok=True)
        listing.write_text(''.join('/'+str(f.relative_to(stage))+'\n' for f in sorted(stage.rglob('*')) if f.is_file() or f.is_symlink()))
        deps=sorted(set(d['deps']))
        if name!='kernel':deps.insert(0,'kernel='+abi)
        info={'name':name,'version':abi,'description':d['Title'],'arch':'aarch64_generic',
              'license':'GPL-2.0-only','origin':'be7000-kmods','url':'https://github.com/Quarx2k/OpenWRT-BE7000',
              'maintainer':'Quarx2k','depends':' '.join(deps)}
        if name=='kernel':info['provides']=' '.join(sorted({Path(f).name for f in builtin}))
        pkg=output/(name+'-'+abi+'.apk')
        args=[apk,'mkpkg','--sign-key',private,'--files',stage,'--output',pkg]
        for key,value in info.items():args+=['--info',key+':'+value]
        if name!='kernel':args+=['--script','post-install:'+str(post),'--script','post-upgrade:'+str(post)]
        run(*args);archives.append(pkg)
    run(apk,'mkndx','--keys-dir',signing,'--sign-key',private,'-o',output/'packages.adb',*archives)
    keys=system/'etc/apk/keys';keys.mkdir(parents=True,exist_ok=True);shutil.copy2(public,keys/public.name)
    before=installed(system)
    # Edit the supported world constraints; apk performs the database transaction.
    world=system/'etc/apk/world'
    keep=[line for line in world.read_text().splitlines() if not re.match(r'^(?:kernel(?:=|$)|kmod-)',line)]
    world.write_text('\n'.join(keep)+'\n')
    seed=config(P/'configs/kernel.config');seed.update(config(P/'configs/netfilter.config'))
    base={'kmod-be7000-platform','kmod-cfg80211','kmod-amneziawg','kmod-tun','kmod-nft-queue','kmod-nft-core',
          'kmod-ipsec4','kmod-ipsec6'} # Required by the EIP197 startup service.
    for mod in re.findall(r'\$base/([\w-]+)\.ko',(P/'runtime/system/opt/be7000/nft/load.sh').read_text()):
        base.add(owners[mod.replace('-','_')])
    for name,d in packages.items():
        options=[v.removeprefix('CONFIG_').split('=')[0] for v in d['config'] if not v.endswith('=n')]
        options=[v for v in options if v in plan['config_symbols']]
        if options and all(seed.get(v) in ['y','m'] for v in options):base.add(name)
    # Drop copied kmods; the selected packages below become their actual owners.
    for module in kernels.glob('*.ko'):module.unlink()
    for rel in ['etc/modules.d','etc/modules-boot.d']:
        shutil.rmtree(system/rel);(system/rel).mkdir()
    common=[apk,'--root',system,'--arch','aarch64_generic','--repositories-file','/dev/null',
            '--repository',str(output/'packages.adb'),'--no-network','--no-scripts']
    run(*common,'add','--upgrade','kernel='+abi,*[n+'='+abi for n in sorted(base)])
    after=installed(system)
    lost={n for n in before if n!='kernel' and not n.startswith('kmod-')} - set(after)
    if lost:raise ValueError('Kernel migration removed userspace packages: '+', '.join(sorted(lost)))
    for name,record in after.items():
        if (name=='kernel' or name.startswith('kmod-')) and '\nV:'+abi+'\n' not in '\n'+record+'\n':
            raise ValueError('Stale generic kernel package: '+name)
    local=system/REPO_PATH
    if local.exists():shutil.rmtree(local)
    shutil.copytree(output,local)
    repos=system/'etc/apk/repositories.d';repos.mkdir(parents=True,exist_ok=True)
    (repos/'be7000.list').write_text('file:///'+REPO_PATH+'/packages.adb\n')
    report={'kernel_abi':abi,'packages':sorted(packages),'preinstalled':sorted(n for n in after if n in packages),
            'excluded':EXCLUDED,'repository':'/'+REPO_PATH,'signed':True,
            'vendor_dependencies':{n:d['vendor_modules'] for n,d in packages.items() if d.get('vendor_modules')}}
    (system/'usr/share/be7000/kmods.json').write_text(json.dumps(report,indent=2)+'\n')
    (work/'kmod-packages.json').write_text(json.dumps(report,indent=2)+'\n')
    return report
