/* SPDX-License-Identifier: GPL-2.0 */
#ifndef KEXEC_ARM64_SECONDARY_PARK_H
#define KEXEC_ARM64_SECONDARY_PARK_H

#include <linux/types.h>

/*
 * The final two pages of Xiaomi's rsvd2 crash_syslog reservation are not
 * allocated by Linux.  The last page is already used for kexec diagnostics;
 * keep the executable holding loop in the preceding page.
 */
#define KEXEC_SECONDARY_PARK_CODE_PHYS	0x4fb3e000ULL
#define KEXEC_SECONDARY_RELEASE_PHYS	0x4fb3eff8ULL
#define KEXEC_SECONDARY_ACK_PHYS		0x4fb3f800ULL
#include "be7000_target.h"
#define KEXEC_SECONDARY_ACK_STRIDE	0x40UL
#define KEXEC_SECONDARY_PARK_WINDOW_SIZE	0x2000UL

#define KEXEC_SECONDARY_STAGE_PARKED	0x00005601U
#define KEXEC_SECONDARY_STAGE_RELEASED	0x00005602U

struct kexec_secondary_ack {
	u32 stage;
	u32 stage_inv;
	u64 mpidr;
	u64 target;
	u8 reserved[KEXEC_SECONDARY_ACK_STRIDE - 24];
};

int kexec_secondary_park_init(void);
void kexec_secondary_park_exit(void);
int kexec_secondary_park_prepare(void);
int kexec_secondary_park_cpus(unsigned long expected_online_mask,
			      unsigned long *parked_mask);
bool kexec_secondary_park_complete(void);

#endif /* KEXEC_ARM64_SECONDARY_PARK_H */
