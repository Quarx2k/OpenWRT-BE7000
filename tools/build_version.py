"""Project version shown by procd and LuCI."""
from pathlib import Path
import re, subprocess

def revision(repo):
    try:
        return subprocess.check_output(['git','-c','safe.directory='+str(repo),'-C',str(repo),
            'describe','--tags','--match','v[0-9]*','--always','--dirty'],text=True,stderr=subprocess.DEVNULL).strip()
    except (OSError,subprocess.CalledProcessError):
        return 'unversioned'

def stamp(system,repo):
    version=revision(repo)
    if not re.fullmatch(r'[A-Za-z0-9._-]+',version):raise ValueError('Invalid build version')
    for name,key,quote in [('etc/openwrt_release','DISTRIB_DESCRIPTION',"'"),('etc/os-release','OPENWRT_RELEASE','"')]:
        path=system/name
        def replace(match):
            base=match[1].split(' / BE7000')[0]
            return f'{key}={quote}{base} / BE7000-OpenWrt {version} by Quarx2k{quote}'
        text,count=re.subn(r'^'+key+'='+quote+'([^\n]*?)'+quote+'$',replace,path.read_text(),flags=re.M)
        if count!=1:raise ValueError(f'Missing {key} in {path}')
        path.write_text(text)
    return version
