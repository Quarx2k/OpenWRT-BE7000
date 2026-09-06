/* SPDX-License-Identifier: GPL-2.0 */
#ifndef KEXEC_BREADCRUMB_H
#define KEXEC_BREADCRUMB_H

/*
 * Xiaomi's rsvd1/rsvd2 regions are persistent crash buffers.  U-Boot copies a
 * buffer beginning with the 0x5ab5 header to the matching MTD partition before
 * the next kernel clears this RAM.
 */
#define XIAOMI_CRASH_LOGBUF_PHYS		0x4fa00000ULL
#define XIAOMI_CRASH_SYSLOG_PHYS		0x4fb00000ULL
#define XIAOMI_CRASH_BUFFER_SIZE		0x00040000UL
#define XIAOMI_CRASH_HEADER_SIZE		0x0000001cUL
#define XIAOMI_CRASH_PAYLOAD_SIZE	(XIAOMI_CRASH_BUFFER_SIZE - \
					 XIAOMI_CRASH_HEADER_SIZE)
#define XIAOMI_CRASH_HEADER_MAGIC	0x00005ab5U
#define XIAOMI_CRASH_HEADER_TEXT		0x00000001U

/* Keep the fixed record in the final 4 KiB, away from normal syslog writes. */
#define KEXEC_BREADCRUMB_OFFSET	0x0003f000UL
#define KEXEC_BREADCRUMB_PHYS	(XIAOMI_CRASH_SYSLOG_PHYS + \
				 KEXEC_BREADCRUMB_OFFSET)
#define KEXEC_BREADCRUMB_MAGIC	0x4b584252U /* "KXBR" */
#define KEXEC_BREADCRUMB_VERSION	0x00040003U

/*
 * Serialized state shared with the replacement kernel.  This lives after the
 * breadcrumb diagnostics in the same final 4 KiB crash_syslog page.  It must
 * contain no pointers: every Linux object is rebuilt by the new kernel.
 */
#define KEXEC_RPM_GLINK_HANDOFF_OFFSET	0x00000300UL
#define KEXEC_RPM_GLINK_HANDOFF_PHYS	(KEXEC_BREADCRUMB_PHYS + \
					 KEXEC_RPM_GLINK_HANDOFF_OFFSET)
#define KEXEC_RPM_GLINK_HANDOFF_MAGIC	0x484c4752U /* "RGLH" */
#define KEXEC_RPM_GLINK_HANDOFF_VERSION	1U
#define KEXEC_RPM_GLINK_HANDOFF_READY	1U
#define KEXEC_RPM_GLINK_HANDOFF_INJECTED	2U
#define KEXEC_RPM_GLINK_HANDOFF_ADOPTED	3U
#define KEXEC_RPM_GLINK_HANDOFF_IDLE	0x00000001U
#define KEXEC_CPU_HANDOFF_READY		0x00005502U
#define KEXEC_CPU_HANDOFF_PARKED		0x00005602U

struct kexec_rpm_glink_handoff {
	u32 magic;
	u32 magic_inv;
	u16 version;
	u16 size;
	u32 state;
	u32 state_inv;
	u32 flags;
	u32 lcid;
	u32 rcid;
	u64 features;
	u32 tx_head;
	u32 tx_tail;
	u32 rx_head;
	u32 rx_tail;
	u32 tx_len;
	u32 rx_len;
	char name[16];
	u32 writer_stage;
	u32 reserved[3];
};

int kexec_breadcrumb_init(void);
void kexec_breadcrumb_write(unsigned int stage);
void kexec_breadcrumb_write_detail(unsigned int stage, u64 arg, u64 context);
void kexec_rpm_glink_handoff_invalidate(void);
int kexec_rpm_glink_handoff_publish(
		const struct kexec_rpm_glink_handoff *record);
void kexec_rpm_glink_handoff_set_cpu_state(u32 writer_stage,
		u32 before_mask, u32 after_mask, int result);
void kexec_breadcrumb_exit(void);

#endif /* KEXEC_BREADCRUMB_H */
