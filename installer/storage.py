"""USB filesystem identity and userdata image selection."""
import json, uuid

USERDATA_SIZES=(256,512,1024,2048)


def select_userdata_image(release,manifest,size):
    if size not in USERDATA_SIZES:raise ValueError('Unsupported storage size')
    name='userdata.img.gz' if size==2048 else f'userdata-{size}.img.gz'
    image=release/name
    if name not in manifest['files'] or not image.is_file():
        raise ValueError('Download the updated image archive to use this storage size.')
    if name!='userdata.img.gz':image.replace(release/'userdata.img.gz')
    for value in USERDATA_SIZES[:-1]:
        name=f'userdata-{value}.img.gz'
        (release/name).unlink(missing_ok=True)
        manifest['files'].pop(name,None)
    manifest['files']['userdata.img.gz']=(release/'userdata.img.gz').stat().st_size
    manifest['userdata_sizes']=[size]
    (release/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')


def ext4_uuid(header):
    # Primary superblock starts at 1024; s_magic is +0x38, s_uuid is +0x68.
    if len(header) != 2048:
        raise ValueError('Incomplete read of the USB ext4 superblock')
    if header[1080:1082] != b'\x53\xef':
        raise ValueError('Selected USB partition has no valid ext4 superblock')
    identity = uuid.UUID(bytes=bytes(header[1128:1144]))
    if identity.int == 0:
        raise ValueError('Selected USB filesystem has no UUID')
    return str(identity)
