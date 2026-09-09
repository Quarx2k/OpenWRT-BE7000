"""Install the persistent Xiaomi launcher without executing it in this boot."""
from pathlib import Path
import re, shlex, tempfile
from kernel_profiles import render_script

ROOT='/data/BE7000-OpenWrt'

def install(client,run,scp,here,target,usb_uuid):
    if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',usb_uuid):
        raise ValueError('Invalid autostart USB UUID')
    q=shlex.quote
    run(client,f'test -f {q(target+"/BOOT_CONTROL_V1")} || '
        '{ echo "Recreate the USB installation with the updated image before enabling autostart." >&2; exit 1; }')
    # Back up the existing firewall exactly once; preserve all other sections.
    run(client,f'''set -eu
test ! -L {ROOT}
mkdir -p {ROOT}
chmod 700 {ROOT}
test -e {ROOT}/firewall.before || cp -p /etc/config/firewall {ROOT}/firewall.before
mkdir -p /tmp/be7000-autostart.lock
''')
    with tempfile.TemporaryDirectory(prefix='be7000-autostart-') as tmp:
        tmp=Path(tmp)
        (tmp/'usb.uuid').write_text(usb_uuid+'\n',encoding='ascii',newline='\n')
        (tmp/'autostart.sh').write_text(render_script(here/'autostart.sh'),encoding='utf-8',newline='\n')
        for name,path in [('autostart.sh',tmp/'autostart.sh'),('hook.sh',here/'autostart-hook.sh'),('usb.uuid',tmp/'usb.uuid')]:
            scp(client,path,ROOT+'/'+name+'.new')
            run(client,f'mv {ROOT}/{name}.new {ROOT}/{name}')
    run(client,f'''set -eu
sh -n {ROOT}/autostart.sh
sh -n {ROOT}/hook.sh
chmod 700 {ROOT}/autostart.sh {ROOT}/hook.sh
uci set firewall.be7000_openwrt=include
uci set firewall.be7000_openwrt.type=script
uci set firewall.be7000_openwrt.path={ROOT}/hook.sh
uci set firewall.be7000_openwrt.enabled=1
uci set firewall.be7000_openwrt.reload=0
uci commit firewall
test ! -L {q(target+'/boot')}
mkdir -p {q(target+'/boot')}
touch {q(target+'/boot/installed')}
rm -f {q(target+'/boot/autostart-disabled')} {q(target+'/boot/xiaomi-once')} {q(target+'/boot/boot-pending')}
sync
''')
