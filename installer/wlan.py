"""Prepare per-router vendor WLAN data without extracting symlinks on Windows."""
import io, json, posixpath, re, shlex, tarfile

MODULES='mem_manager qdf umac telemetry_agent qca_spectral ipq_cnss2 qca_ol smart_antenna rawmode_sim wifi_3_0 monitor ath_pktlog'.split()
CALIBRATION=['IPQ9574/caldata.bin','qcn9224/caldata_3.bin']
PATHS=['lib/modules/5.4.164/'+n+'.ko' for n in MODULES]+['lib/firmware/IPQ9574','lib/firmware/qcn9224','ini']
ACCEL_FIRMWARE=['ifpp.bin','ipue.bin','ofpp.bin','opue.bin','qca-nss0.bin']

def mapped(name):
    name=name.removeprefix('./').lstrip('/')
    if '..' in name.split('/'):raise ValueError('Invalid WLAN archive path')
    if name in PATHS[:len(MODULES)]:return 'modules/'+posixpath.basename(name)
    if name in ['lib/firmware/'+f for f in ACCEL_FIRMWARE]:return 'firmware/'+posixpath.basename(name)
    for prefix,dest in [('lib/firmware/IPQ9574','firmware/IPQ9574'),('lib/firmware/qcn9224','firmware/qcn9224'),('ini','ini')]:
        if name==prefix or name.startswith(prefix+'/'):return dest+name[len(prefix):]
    raise ValueError('Unexpected WLAN archive member: '+name)

def prepare(data,output,kernel):
    entries={};payloads={};sizes={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:') as src:
        for member in src:
            original=member.name.removeprefix('./').lstrip('/').rstrip('/')
            name=mapped(original)
            if any(name=='firmware/'+c or name.startswith('firmware/'+c+'/') for c in CALIBRATION):continue
            if name in entries:raise ValueError('Duplicate WLAN archive member: '+name)
            info=tarfile.TarInfo(name);info.mode=0o700 if member.isdir() else 0o600
            if member.isdir():info.type=tarfile.DIRTYPE
            elif member.issym() or member.islnk():
                target=posixpath.normpath(member.linkname if member.islnk() or member.linkname.startswith('/') else posixpath.join(posixpath.dirname(original),member.linkname))
                info.type=tarfile.SYMTYPE
                info.linkname=posixpath.relpath(mapped(target),posixpath.dirname(name))
            elif member.isfile():
                content=src.extractfile(member).read();info.size=len(content);payloads[name]=content
                if name.startswith('modules/'):
                    if content[:6]!=b'\x7fELF\x02\x01' or content[18:20]!=b'\xb7\x00':raise ValueError('Expected an AArch64 WLAN module: '+name)
                    if not re.search(rb'vermagic=5\.4\.164(?: |\x00)',content):raise ValueError('WLAN kernel release mismatch: '+name)
                    sizes[posixpath.basename(name)]=len(content)
            else:raise ValueError('Unsupported WLAN archive entry: '+name)
            entries[name]=info
    for n in MODULES:
        if 'modules/'+n+'.ko' not in payloads:raise ValueError('Missing WLAN module: '+n)
    def present(name,seen=None):
        seen=set() if seen is None else seen
        if name in seen:raise ValueError('WLAN symlink loop: '+name)
        seen.add(name)
        for candidate in [name,*[name.rsplit('/',i)[0] for i in range(1,name.count('/')+1)]]:
            entry=entries.get(candidate)
            if entry and entry.issym():
                target=posixpath.normpath(posixpath.join(posixpath.dirname(candidate),entry.linkname))
                return present(target+name[len(candidate):],seen)
        return name in payloads and bool(payloads[name])
    for name in ['firmware/IPQ9574/q6_fw.mdt','firmware/qcn9224/amss.bin','ini/global.ini']:
        if not present(name):raise ValueError('Missing WLAN firmware/config: '+name)
    # Firmware requests INI files by basename as well as through /ini.
    for name in list(entries):
        if name.startswith('ini/') and name.count('/')==1:
            alias='firmware/'+name[4:]
            if alias not in entries:
                entry=tarfile.TarInfo(alias);entry.type=tarfile.SYMTYPE;entry.linkname='../'+name;entries[alias]=entry
    report={'origin':'installing router','kernel':kernel,'modules':sizes,'cfg80211':'supplied by source-built system image',
            'acceleration_firmware':[name for name in ACCEL_FIRMWARE if present('firmware/'+name)]}
    with tarfile.open(output,'w:gz') as dst:
        for name,entry in entries.items():dst.addfile(entry,io.BytesIO(payloads[name]) if name in payloads else None)
        for name in CALIBRATION:
            entry=tarfile.TarInfo('firmware/'+name);entry.type=tarfile.SYMTYPE
            entry.linkname='/opt/be7000/calibration/'+name;dst.addfile(entry)
        content=(json.dumps(report,indent=2)+'\n').encode();entry=tarfile.TarInfo('manifest.json');entry.size=len(content);entry.mode=0o600
        dst.addfile(entry,io.BytesIO(content))
    return report

def collect(client,run,output):
    # Fixed allowlist; read-only. No dependency on SFTP or a firmware ROM number.
    kernel={'release':run(client,'uname -r').decode().strip(),'build':run(client,'uname -v').decode().strip()}
    # Copy optional accelerator firmware from this router, never bundle it.
    extra=run(client,'for f in '+' '.join('lib/firmware/'+f for f in ACCEL_FIRMWARE)+'; do [ ! -s "/$f" ] || echo "$f"; done').decode().split()
    if any(f not in ['lib/firmware/'+n for n in ACCEL_FIRMWARE] for f in extra):raise ValueError('Unexpected accelerator firmware path')
    data=run(client,'tar -cf - -C / '+' '.join(PATHS+extra),120)
    return prepare(data,output,kernel)

def collect_missing_acceleration(client,run,target):
    dest=shlex.quote(target+'/device/wlan/firmware')
    run(client,'dest='+dest+'; [ -d "$dest" ] || exit 0; for name in '+' '.join(ACCEL_FIRMWARE)+
        '; do if [ -s "/lib/firmware/$name" ] && [ ! -s "$dest/$name" ]; then '
        'cp "/lib/firmware/$name" "$dest/$name" || exit 1; fi; done; sync')
