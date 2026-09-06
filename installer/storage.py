"""Read the ext4 identity without requiring blkid on Xiaomi stock firmware."""
import uuid


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
