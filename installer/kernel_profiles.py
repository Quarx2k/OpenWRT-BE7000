"""Audited Xiaomi kernels sharing the sender's device/GLINK ABI."""
from pathlib import Path
import shlex

PROFILES={
    '20240122':{'firmware':'1.1.16','build':'#0 SMP PREEMPT Mon Jan 22 02:33:42 2024',
                'pen':'ffffffc0107f51a4'},
    '20260127':{'firmware':'1.1.38','build':'#0 SMP PREEMPT Tue Jan 27 03:33:27 2026',
                'pen':'ffffffc0107f61a4'},
}
MARKER='# @BE7000_KERNEL_PROFILE@'

def render_script(path):
    """Inline the same detector in boot scripts, including legacy sysupgrade files."""
    script=Path(path).read_text()
    if MARKER not in script:return script
    cases='\n'.join(f'        {shlex.quote(p["build"])}) KERNEL_PROFILE={key}; KERNEL_FIRMWARE={p["firmware"]}; KERNEL_PEN={p["pen"]};;'
                    for key,p in PROFILES.items())
    detector='''be7000_kernel_profile() {
    [ "$(uname -m)" = aarch64 ] && [ "$(uname -r)" = 5.4.164 ] || {
        echo 'Unsupported Xiaomi kernel architecture or version' >&2; return 1;
    }
    case "$(uname -v)" in
'''+cases+'''
        *) echo 'Supported Xiaomi kernels: 22 January 2024 and 27 January 2026' >&2; return 1;;
    esac
    grep -qx "$KERNEL_PEN T secondary_holding_pen" /proc/kallsyms || {
        echo 'This Xiaomi kernel build is not supported.' >&2; return 1;
    }
}
'''
    return script.replace(MARKER,detector.rstrip())

def parse_preflight(report):
    lines=report.decode().splitlines()
    profiles=[line.partition('=')[2] for line in lines if line.startswith('BE7000_KERNEL_PROFILE=')]
    if len(profiles)!=1 or profiles[0] not in PROFILES:
        raise ValueError('Installer could not identify the Xiaomi kernel')
    return profiles[0],'\n'.join(line for line in lines if not line.startswith('BE7000_KERNEL_PROFILE='))

def check_bundle(manifest,profile):
    # Existing single-kernel releases are usable only on their original 2026 base.
    if profile not in manifest.get('supported_kernels',['20260127']):
        raise ValueError('This bundle does not support the router kernel. Use the updated Windows/Linux release archive.')

def check_existing(client,run,target,profile):
    module=shlex.quote(target+'/payload/kexec_mod.ko')
    supported=run(client,f'''set -eu
test -s {module}
profiles=$(strings {module} | sed -n 's/^be7000_source_kernels=//p')
[ -n "$profiles" ] || profiles=20260127
printf '%s\\n' "$profiles"
''').decode().strip().split(',')
    if profile not in supported:
        raise ValueError('The saved installation does not support this Xiaomi kernel. Update OpenWrt or choose Recreate.')
