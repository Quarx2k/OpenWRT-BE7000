"""Package our USB images for the standard LuCI/sysupgrade validation path."""
from pathlib import Path
import io, json, subprocess, tarfile

FORMAT='be7000-usb-sysupgrade-v1'
PREFIX='sysupgrade-be7000'
FILES=['system.img.gz','userdata.img.gz','manifest.json','provenance.json']+[
    'payload/'+name for name in [
        '01-load-only.sh','02-execute.sh','02-quiesce-stage2.sh','03-cancel.sh',
        '06-check-layout.sh','Image','System.map','kexec','kexec_mod.ko',
        'kexec_mod_arm64.ko','target-layout.json']]

def package(release,output,fwtool,version):
    release=Path(release);output=Path(output)
    for name in FILES:
        if not (release/name).is_file() or not (release/name).stat().st_size:
            raise ValueError('Missing sysupgrade component: '+name)
    with tarfile.open(output,'w',format=tarfile.USTAR_FORMAT) as archive:
        for name,data in [('FORMAT',(FORMAT+'\n').encode()),
                          ('FILES',''.join(f'{(release/n).stat().st_size} {n}\n' for n in FILES).encode())]:
            member=tarfile.TarInfo(PREFIX+'/'+name);member.size=len(data);member.mode=0o644
            archive.addfile(member,io.BytesIO(data))
        for name in FILES:
            member=archive.gettarinfo(release/name,arcname=PREFIX+'/'+name)
            member.uid=member.gid=0;member.uname=member.gname='root'
            member.mode=0o644
            with (release/name).open('rb') as source:archive.addfile(member,source)
    metadata=output.with_suffix('.metadata.json')
    metadata.write_text(json.dumps({
        'metadata_version':'1.1','compat_version':'1.0',
        'supported_devices':['xiaomi,be7000'],
        'version':{'dist':'BE7000-OpenWrt','version':version,'target':'armsr/armv8','board':'xiaomi,be7000'},
        'be7000_format':FORMAT},indent=2)+'\n')
    subprocess.run([str(fwtool),'-I',str(metadata),str(output)],check=True)
    return output
