#!/usr/bin/env python3
"""Interactive Windows/Linux USB installer. The original firmware is never flashed."""
import argparse, base64, getpass, hashlib, ipaddress, json, os, re, shlex, sys, tarfile, tempfile, time, traceback
import urllib.request
from pathlib import Path
import paramiko
from devicetree import spin_table
from storage import ext4_uuid, USERDATA_SIZES, select_userdata_image
from wlan import collect as collect_wlan
from wlan import collect_missing_acceleration
from autostart import install as install_autostart
from ui import ask, choose, confirm, say, styled
from kernel_profiles import render_script, parse_preflight, check_bundle, check_existing

VERSION='1.0.3'
RELEASE=f'https://github.com/Quarx2k/OpenWRT-BE7000/releases/download/v{VERSION}/BE7000-OpenWrt-{VERSION}.tar.gz'
BASE='BE7000-OpenWrt'
DEVICE_CHECK='[ -c /dev/kexec ] || die "/dev/kexec was not created"'
DEVICE_WAIT='''# Wait for Xiaomi hotplug to create /dev/kexec.
waited=0
while [ ! -c /dev/kexec ] && [ "$waited" -lt 30 ]; do
\tsleep 1
\twaited=$((waited + 1))
done
'''
LEGACY_CRASH_CHECK='''CRASH_UPLOAD=$(uci -q get miwifi.server.LOG 2>/dev/null || true)
[ "$CRASH_UPLOAD" = "127.0.0.1:9" ] ||
\tdie "crash-log retention stub is not armed (miwifi.server.LOG=${CRASH_UPLOAD:-unset})"
'''

def local_bundle():
    frozen=getattr(sys,'frozen',False)
    directory=Path(sys.executable if frozen else __file__).resolve().parent
    directories=[directory] if frozen else [directory.parent,directory]
    return next((p for d in directories if (p:=d/f'BE7000-OpenWrt-{VERSION}.tar.gz').is_file()),None)

def run(client, command, timeout=60):
    _,out,err=client.exec_command(command,timeout=timeout)
    data=out.read();error=err.read()
    code=out.channel.recv_exit_status()
    if code:
        raise RuntimeError(error.decode(errors='replace')+data.decode(errors='replace') or f'Router command failed (exit {code})')
    return data

def scp(client, file, target):
    channel=client.get_transport().open_session();channel.settimeout(120)
    channel.exec_command('scp -t '+shlex.quote(target.rsplit('/',1)[0]))
    def ack():
        code=channel.recv(1)
        if code!=b'\0':raise RuntimeError('SCP transfer rejected by router')
    ack();channel.sendall(f'C0600 {file.stat().st_size} {target.rsplit("/",1)[1]}\n'.encode());ack()
    with file.open('rb') as f:
        while block:=f.read(128*1024):channel.sendall(block)
    channel.sendall(b'\0');ack();channel.close()

def update_boot_scripts(client,payload):
    # Patch installed scripts without replacing their generated kernel layout.
    for name in ['01-load-only.sh','02-execute.sh']:
        path=payload+'/'+name
        script=run(client,'cat '+shlex.quote(path)).decode()
        if name=='01-load-only.sh':
            if DEVICE_WAIT in script:continue
            if script.count(DEVICE_CHECK)!=1:
                raise RuntimeError('The saved loader could not be updated. Use the matching image archive.')
            updated=script.replace(DEVICE_CHECK,DEVICE_WAIT+DEVICE_CHECK)
        else:
            updated=script.replace(LEGACY_CRASH_CHECK,'')
            if updated==script:continue
        with tempfile.TemporaryDirectory() as temp:
            local=Path(temp)/name
            local.write_bytes(updated.encode())
            pending=path+'.new'
            scp(client,local,pending)
            run(client,f'sh -n {shlex.quote(pending)} && chmod 700 {shlex.quote(pending)} && mv -f {shlex.quote(pending)} {shlex.quote(path)}')

def fingerprint(key):
    return 'SHA256:'+base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')

class TrustFirstUse(paramiko.MissingHostKeyPolicy):
    def missing_host_key(self, client, hostname, key):
        say(f'First SSH connection to {hostname}: {key.get_name()} {fingerprint(key)}','warning')
        if not confirm('Trust this router key?'):
            raise RuntimeError('SSH key not accepted')
        client.get_host_keys().add(hostname,key.get_name(),key)
        client.save_host_keys(str(KEYS))

KEYS=Path.home()/'.be7000-openwrt/known_hosts'

def existing_installation(client,target):
    p=shlex.quote(target)
    if not run(client,f'if [ -e {p} ] || [ -L {p} ]; then echo exists; fi').strip():return 'new'
    say('Installation already exists: '+target,'warning')
    choice=choose('Installation option number',[
        'Use existing installation (keep settings)',
        'Recreate installation (delete existing system and settings)',
        'Cancel'])
    return {1:'existing',2:'replace',3:'cancel'}[choice]

def remove_installation(client,dev,mount,target):
    if not re.fullmatch(r'/mnt/usb-[A-Za-z0-9_-]+',mount) or target!=mount+'/'+BASE:
        raise ValueError('Unexpected USB installation path')
    q=shlex.quote
    return run(client,f'''set -eu
p={q(target)}
[ ! -L "$p" ] && [ "$(readlink -f "$p")" = "$p" ] || {{ echo 'Refusing to remove a redirected installation path' >&2; exit 1; }}
awk -v d={q(dev)} -v m={q(mount)} '$1==d && $2==m && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/ {{ found=1 }} END {{ exit !found }}' /proc/mounts || {{ echo 'Selected USB mount changed' >&2; exit 1; }}
awk -v p="$p" '$2==p || index($2,p"/")==1 {{ busy=1 }} END {{ exit busy }}' /proc/mounts || {{ echo 'Installation contains mounted filesystems' >&2; exit 1; }}
awk -v p="$p" 'index($1,p"/")==1 {{ busy=1 }} END {{ exit busy }}' /proc/swaps || {{ echo 'Installation swap is still active' >&2; exit 1; }}
for f in /sys/block/loop*/loop/backing_file; do
    [ -r "$f" ] || continue
    backing=$(cat "$f")
    case "/${{backing#/}}" in "$p"/*) echo 'Installation image is still mounted' >&2; exit 1;; esac
done
rm -rf -- "$p"
[ ! -e "$p" ] && [ ! -L "$p" ]
''',120)

def connect_router(host,port,password):
    client=paramiko.SSHClient();KEYS.parent.mkdir(parents=True,exist_ok=True)
    if KEYS.exists():client.load_host_keys(str(KEYS))
    client.set_missing_host_key_policy(TrustFirstUse())
    options=dict(port=port,username='root',password=password,
                 allow_agent=False,look_for_keys=False,timeout=10)
    try:
        try:
            client.connect(host,**options)
        except paramiko.BadHostKeyException as error:
            client.close()
            say(f'SSH key changed for {host}. Xiaomi firmware may regenerate it after a reboot.','warning')
            print('Saved key:',fingerprint(error.expected_key))
            print('New key:  ',fingerprint(error.key))
            if not confirm('Accept the new key for this router?'):
                raise RuntimeError('SSH key not accepted') from None
            name=host if port==22 else f'[{host}]:{port}'
            client.get_host_keys().add(name,error.key.get_name(),error.key)
            try:client.connect(host,**options)
            except paramiko.BadHostKeyException:
                raise RuntimeError('SSH key changed again while reconnecting; please retry') from None
            client.get_host_keys().save(str(KEYS))
        return client
    except BaseException:
        client.close()
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host');parser.add_argument('--port',type=int,default=22)
    parser.add_argument('--bundle',type=Path)
    parser.add_argument('--action',choices=['prepare','load','boot','autostart'],default='boot')
    parser.add_argument('--preflight-only',action='store_true')
    parser.add_argument('--boot-existing',action='store_true')
    args=parser.parse_args()
    say('Xiaomi BE7000-OpenWrt by Quarx2k - USB boot, Xiaomi 1.1.16 / 1.1.38 kernels')
    host=args.host or ask('Router IP [192.168.32.1]: ').strip() or '192.168.32.1'
    ipaddress.ip_address(host)
    client=connect_router(host,args.port,getpass.getpass(styled('Router SSH password: ')))
    logdir=KEYS.parent/'logs'/time.strftime('%Y%m%d-%H%M%S');logdir.mkdir(parents=True)
    here=Path(getattr(sys,'_MEIPASS',Path(__file__).resolve().parent))
    try:
        # Execute a reviewed read-only script over stdin, without creating a remote file.
        inp,out,err=client.exec_command('sh -s',timeout=20)
        inp.write(render_script(here/'preflight.sh'));inp.channel.shutdown_write()
        report=out.read()+err.read();(logdir/'preflight.txt').write_bytes(report)
        if out.channel.recv_exit_status():raise RuntimeError(report.decode(errors='replace'))
        kernel_profile,message=parse_preflight(report)
        say(message.strip(),'success')
        (logdir/'kernel-profile.txt').write_text(kernel_profile+'\n',encoding='ascii')
        if args.preflight_only:return
        if args.action=='boot':
            mode=choose('Boot mode number',['Boot once','Enable automatic startup and boot now'])
            if mode==2:args.action='autostart'
        mounts=run(client,'cat /proc/mounts').decode().splitlines()
        candidates=[]
        for line in mounts:
            fields=line.split()
            if fields[0].startswith('/dev/sd') and fields[1].startswith('/mnt/usb-') and fields[2]=='ext4' and 'rw' in fields[3].split(','):
                if 'noexec' in fields[3].split(','):continue
                # Quiesce explicitly detaches /mnt/usb-* mounts before kexec.
                if not re.fullmatch(r'/mnt/usb-[A-Za-z0-9_/-]+',fields[1]):continue
                name=fields[0].rsplit('/',1)[1]
                if '/usb' not in run(client,'readlink -f /sys/class/block/'+name).decode():continue
                candidates.append((fields[0],fields[1]))
        if not candidates:raise RuntimeError('Mount an ext4 USB partition in the original firmware first. No disks were formatted.')
        choice=choose('USB number',[f'{dev} at {mount}' for dev,mount in candidates])-1
        dev,mount=candidates[choice]
        # Stock BusyBox omits blkid. Read only the first 2 KiB of the selected partition.
        usb_uuid=ext4_uuid(run(client,'dd if='+shlex.quote(dev)+' bs=1024 count=2 2>/dev/null'))
        print('USB filesystem UUID:',usb_uuid)
        target=mount+'/'+BASE
        q=shlex.quote
        action='existing' if args.boot_existing else existing_installation(client,target)
        if action=='cancel':return
        args.boot_existing=action=='existing'
        if args.boot_existing:
            run(client,f'test -f {q(target+"/READY")} && test -f {q(target+"/payload/launch.conf")} && '
                f'test -s {q(target+"/system.img")} && test -s {q(target+"/userdata.img")} || '
                '{ echo "Installation is incomplete. Run again and choose Recreate." >&2; exit 1; }')
            check_existing(client,run,target,kernel_profile)
            if args.action=='autostart' and not confirm('Enable automatic USB startup and boot OpenWrt now?'):return
            collect_missing_acceleration(client,run,target)
        else:
            available=int(run(client,'df -Pk '+q(mount)).decode().splitlines()[-1].split()[3])*1024
            if action=='replace':available+=int(run(client,'du -sk '+q(target)).split()[0])*1024
            say('Space for settings and installed packages:')
            userdata=USERDATA_SIZES[choose('Storage size number',[f'{size} MiB' for size in USERDATA_SIZES])-1]
            swap_sizes=[0,256,512,1024]
            swap_choice=choose('Swap option number',[f'{size} MiB' if size else 'No swap' for size in swap_sizes])
            swap=swap_sizes[swap_choice-1]
            if available<(1024+userdata+swap)*1024**2:raise RuntimeError('Insufficient free USB space for the selected sizes')
            if swap:run(client,'command -v mkswap')
            diag=confirm('Reserve diagnostic LAN eth1 + SSH 2222?')
            peer=''
            if diag:
                peer=ask('Optional recovery peer IP (300s outage reboots); blank disables watchdog: ').strip()
                if peer:ipaddress.IPv4Address(peer)
            operation=f'Recreate {target}, deleting its system and ALL settings,' if action=='replace' else f'Install into {target}'
            finish='enable automatic startup and boot OpenWrt now' if args.action=='autostart' else args.action
            if not confirm(f'{operation} and {finish}?'):return
            with tempfile.TemporaryDirectory(prefix='be7000-') as temp:
                temp=Path(temp);bundle=args.bundle
                if bundle is None:bundle=local_bundle()
                if bundle is None:
                    bundle=temp/'release.tar.gz';say('Downloading release…')
                    urllib.request.urlretrieve(RELEASE,bundle)
                with tarfile.open(bundle) as t:
                    t.extractall(temp/'release',filter='data')
                release=temp/'release';manifest=json.loads((release/'manifest.json').read_text())
                if manifest['version']!=VERSION:raise ValueError('Installer/release version mismatch')
                if manifest.get('vendor_delivery')!='installer-v1':raise ValueError('Use the latest release archive.')
                check_bundle(manifest,kernel_profile)
                for name,size in manifest['files'].items():
                    f=release/name
                    if not f.resolve().is_relative_to(release.resolve()) or f.stat().st_size!=size:
                        raise ValueError('Missing or truncated release file: '+name)
                select_userdata_image(release,manifest,userdata)
                (release/'payload/be7000-spin-table.dtb').write_bytes(spin_table(run(client,'cat /sys/firmware/fdt')))
                device=release/'device';device.mkdir()
                for rel,size in [('IPQ9574/caldata.bin',131072),('qcn9224/caldata_3.bin',184320)]:
                    data=run(client,'cat /tmp/'+rel)
                    if len(data)!=size:raise ValueError('Unexpected calibration size: '+rel)
                    dest=device/'calibration'/rel;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
                say('Reading this router’s WLAN modules and firmware…')
                wlan_report=collect_wlan(client,run,device/'wlan.tar.gz')
                (logdir/'wlan.json').write_text(json.dumps(wlan_report,indent=2),encoding='utf-8')
                macs=[]
                for iface in ['wifi0','wifi1']:
                    mac=run(client,'cat /sys/class/net/'+iface+'/address').decode().strip()
                    if not re.fullmatch(r'(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}',mac):raise ValueError('Invalid Wi-Fi MAC')
                    if int(mac[:2],16)&1:raise ValueError('Multicast Wi-Fi MAC')
                    macs.append(mac)
                if macs[0]==macs[1]:raise ValueError('Router Wi-Fi MACs are identical; refusing to invent device identity')
                env={'WIFI_MAC_2G':macs[0],'WIFI_MAC_5G':macs[1],'GUARD_PEER':peer,'SWAP_MIB':str(swap)}
                if diag:
                    keyfile=KEYS.parent/'rescue_rsa'
                    if keyfile.exists():key=paramiko.RSAKey.from_private_key_file(str(keyfile))
                    else:
                        key=paramiko.RSAKey.generate(3072);key.write_private_key_file(str(keyfile))
                        keyfile.chmod(0o600)
                    (device/'rescue_authorized_keys').write_text(key.get_name()+' '+key.get_base64()+' be7000-rescue\n',encoding='utf-8',newline='\n')
                    print('Diagnostic SSH private key saved on this PC:',keyfile)
                (device/'provision.env').write_text(''.join(k+'='+q(v)+'\n' for k,v in env.items()),encoding='utf-8',newline='\n')
                (release/'payload/launch.conf').write_text(f'USB_UUID={q(usb_uuid)}\nDIAGNOSTIC={int(diag)}\n',encoding='utf-8',newline='\n')
                upload=temp/'upload.tar.gz'
                with tarfile.open(upload,'w:gz') as t:
                    for f in release.iterdir():t.add(f,arcname=f.name)
                if action=='replace':
                    (logdir/'recreate.txt').write_bytes(remove_installation(client,dev,mount,target))
                run(client,'umask 077; mkdir '+q(target))
                say('Uploading images, WLAN files and this router’s calibration…')
                try:scp(client,upload,target+'/install.tar.gz')
                except TimeoutError as error:
                    raise RuntimeError('File upload timed out. Check the router connection and USB drive.') from error
                except EOFError as error:
                    raise RuntimeError('The connection closed while uploading files.') from error
                (logdir/'upload.txt').write_text(f'Uploaded {upload.stat().st_size} bytes\n',encoding='ascii')
                say('Preparing the USB drive. This may take several minutes…')
                command=(f'cd {q(target)} && tar -xzf install.tar.gz && '
                         'gzip -dc system.img.gz > system.img && gzip -dc userdata.img.gz > userdata.img && '
                         'chmod 700 payload/*.sh payload/kexec && chmod -R go-rwx device && '
                         'mkdir -m 700 device/wlan && tar -xzf device/wlan.tar.gz -C device/wlan && rm device/wlan.tar.gz && '
                         'test "$(wc -c < system.img)" = 536870912 && '
                         f'test "$(wc -c < userdata.img)" = {userdata*1024**2} && '
                         'rm install.tar.gz system.img.gz userdata.img.gz && ')
                if swap:
                    command+=f'dd if=/dev/zero of=swap.img bs=1048576 count={swap} && chmod 600 swap.img && mkswap swap.img && '
                # Stable aliases let sysupgrade switch kernel, rootfs and overlay
                # together with one atomic current-symlink replacement.
                command+=('mkdir -p slots/a && mv system.img userdata.img payload slots/a/ && '
                          'ln -s slots/a current && ln -s current/system.img system.img && '
                          'ln -s current/userdata.img userdata.img && ln -s current/payload payload && '
                          'touch USB_SLOTS_V1 READY && sync')
                try:result=run(client,command,1800)
                except TimeoutError as error:
                    raise RuntimeError('USB preparation timed out. Check the USB drive before retrying.') from error
                except EOFError as error:
                    raise RuntimeError('The connection closed while preparing the USB drive.') from error
                (logdir/'install.txt').write_bytes(result)
        payload=target+'/payload'
        update_boot_scripts(client,payload)
        if args.action=='autostart':
            install_autostart(client,run,scp,here,target,usb_uuid)
            say('Autostart enabled (three attempts).','success')
            print('In OpenWrt: System → Boot system. Without the USB drive, Xiaomi firmware starts.')
        if args.action=='prepare':
            say('Prepared. Run again with --boot-existing to boot.','success');return
        say('Loading the kernel into RAM…')
        try:
            loaded=run(client,f'cd {q(payload)} && sh 01-load-only.sh LOAD-OWRT12-CANDIDATE',120)
        except Exception:
            for name,command in [('dmesg.txt','dmesg'),('load-state.txt',
                'cat /proc/modules; cat /proc/mounts; ls -l /dev/kexec /sys/class/kexec/kexec/dev /sys/kernel/kexec_loaded')]:
                try:(logdir/name).write_bytes(run(client,command+'; true',15))
                except Exception:pass
            raise
        (logdir/'load.txt').write_bytes(loaded)
        (logdir/'load-logs.tar').write_bytes(run(client,f'tar -cf - -C {q(payload)} logs loaded-state.txt'))
        if args.action=='load':
            say('Loaded only; no transition. Use payload/03-cancel.sh on the router to cancel.','success');return
        (logdir/'execute.txt').write_bytes(run(client,f'cd {q(payload)} && sh 02-execute.sh EXECUTE-KEXEC-QUIESCED',30))
        say('Transition armed. Keep power connected. Open http://192.168.1.1 after boot.','success')
        print('Set the root password, country and Wi-Fi security in LuCI. Both radios start disabled.')
        print('The PC may need DHCP renewal. USB settings persist.')
        if args.action=='autostart':
            print('Future router boots start OpenWrt automatically while this USB drive is connected.')
        else:
            print('Without autostart, normal reboot returns to the original firmware.')
        print('Logs:',logdir)
    except Exception:
        (logdir/'error.txt').write_text(traceback.format_exc(),encoding='utf-8')
        print('Logs:',logdir)
        raise
    finally:client.close()

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as e:
        message='Cancelled' if isinstance(e,KeyboardInterrupt) else str(e) or 'Operation failed'
        print(styled('Stopped: '+message,'error'),file=sys.stderr)
        sys.exit(1)
    finally:
        if getattr(sys,'frozen',False) and sys.stdin.isatty():
            try:input('Press Enter to close…')
            except (EOFError,KeyboardInterrupt):pass
