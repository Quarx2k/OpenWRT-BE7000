"""Build the IPQ95xx acceleration profile and its kernel dependencies."""
from pathlib import Path
import json, shutil

def build(work, kernel, common, symbols, includes, checkout, run):
    repo=Path(__file__).resolve().parents[1]
    profiles=json.loads((repo/'configs/acceleration.json').read_text())
    for name in ['emesh-sp','nss-drv','nss-eip','nss-nsm','nss-speedtest','qca-nss-ecm','qca-ovsmgr','shortcut-fe']:
        checkout(work,name)
    shutil.copy2(work/'nss-drv/exports/arch/nss_ipq95xx.h',work/'nss-drv/exports/nss_arch.h')
    headers=repo/'compat/ecm-wifi'
    includes += [work/p for p in ['ppe/drv/ppe_ds/exports','dp/exports','shortcut-fe/exports',
        'nss-eip/driver/exports','nss-eip/clients/exports','qca-nss-ecm/exports',
        'include/nat46','nss-drv/exports','qca-ovsmgr/exports','emesh-sp']]+[headers,kernel/'net/openvswitch']
    flags=' '.join('-I'+str(p) for p in includes)
    built=[]
    def module(path, options=()):
        tree=work/path
        extra=' -DNSS_CAPWAPMGR_ONE_NETDEV' if path=='ppe/clients/capwapmgr' else ''
        run(*common,'M='+str(tree),'SoC=ipq95xx','BUILD_ID=\\\"be7000-1.0.0\\\"',
            'EXTRA_CFLAGS='+flags+extra,'KBUILD_EXTRA_SYMBOLS='+' '.join(map(str,symbols)),*options,'modules')
        symbols.append(tree/'Module.symvers')
        built.extend(Path(line) for line in (tree/'modules.order').read_text().splitlines())
    # Build standard dependencies against the same configured kernel.
    deps=work/'accel-kernel/deps';deps.mkdir(parents=True,exist_ok=True)
    for rel in ['drivers/net/vxlan.c','crypto/authenc.c','net/xfrm/xfrm_algo.c','net/ipv4/esp4.c','net/ipv6/esp6.c']:
        shutil.copy2(kernel/rel,deps/Path(rel).name)
    (deps/'Makefile').write_text('obj-m := vxlan.o authenc.o xfrm_algo.o esp4.o esp6.o\n')
    module('accel-kernel/deps')
    for source,opts in [('drivers/net/bonding',()),('net/l2tp',()),
                        ('net/nsh',('CONFIG_NET_NSH=m',)),('net/openvswitch',('CONFIG_OPENVSWITCH=m',))]:
        tree=work/'accel-kernel'/Path(source).name
        shutil.copytree(kernel/source,tree,dirs_exist_ok=True)
        module(str(tree.relative_to(work)),opts)
    for path,profile in [('emesh-sp',None),('nss-drv','nss-lite'),('nss-eip','eip'),
                         ('qca-ovsmgr',None),('nss-speedtest/nss-udp-st-drv',None),
                         ('ppe/drv/ppe_rule','rule'),('ppe/clients/vlan',None),('ppe/clients/pppoe',None),
                         ('ppe/clients/bridge',None),('ppe/clients/lag',None),('ppe/drv/ppe_vp',None),
                         ('shortcut-fe','sfe'),('ppe/drv/ppe_ds',None),('ppe/drv/ppe_tun',None),
                         ('ppe/clients/gretap',None),('ppe/clients/mapt',None),('ppe/clients/tunipip6',None),
                         ('ppe/clients/vxlanmgr',None),('ppe/clients/capwapmgr',None)]:
        module(path,profiles.get(profile,()))
    # These are declarations of real vendor exports, not replacement functions.
    vendor_symbols=work/'accel-kernel/wlan.symvers'
    vendor_symbols.write_text(''.join('0x00000000\t'+name+'\t'+provider+'\tEXPORT_SYMBOL\t\n'
        for name,provider in json.loads((headers/'exports.json').read_text()).items()))
    symbols.append(vendor_symbols)
    module('qca-nss-ecm',profiles['ecm'])
    module('nss-nsm')
    module('nss-eip/clients/ipsec',profiles['eip-ipsec'])
    return built
