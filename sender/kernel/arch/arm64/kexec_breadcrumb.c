// SPDX-License-Identifier: GPL-2.0
/* Persistent stage markers exported through Xiaomi's crash_syslog path. */

#include <linux/errno.h>
#include <linux/io.h>
#include <linux/module.h>

#include "../../kexec_breadcrumb.h"

static void __iomem *crash_logbuf_base;
static void __iomem *crash_syslog_base;
static void __iomem *breadcrumb_base;
static void __iomem *rpm_glink_handoff_base;

static void xiaomi_crash_buffer_arm(void __iomem *base)
{
	/* Match the 28-byte headers written by the stock Xiaomi kernel. */
	writel_relaxed(XIAOMI_CRASH_HEADER_TEXT, base + 4);
	writel_relaxed(XIAOMI_CRASH_PAYLOAD_SIZE, base + 8);
	writel_relaxed(0, base + 12);
	writel_relaxed(0, base + 16);
	writel_relaxed(0, base + 20);
	writel_relaxed(0, base + 24);
	wmb();

	/* U-Boot treats the magic as the commit marker.  Write it last. */
	writel_relaxed(XIAOMI_CRASH_HEADER_MAGIC, base);
	wmb();
}

void kexec_breadcrumb_write(unsigned int stage)
{
	if (!breadcrumb_base)
		return;

	writel_relaxed(stage, breadcrumb_base + 8);
	writel_relaxed(~stage, breadcrumb_base + 12);
	if (crash_logbuf_base) {
		writel_relaxed(stage, crash_logbuf_base +
			       XIAOMI_CRASH_HEADER_SIZE + 8);
		writel_relaxed(~stage, crash_logbuf_base +
			       XIAOMI_CRASH_HEADER_SIZE + 12);
	}
	wmb();
}
EXPORT_SYMBOL_GPL(kexec_breadcrumb_write);

void kexec_breadcrumb_write_detail(unsigned int stage, u64 arg, u64 context)
{
	if (!breadcrumb_base)
		return;

	writel_relaxed(lower_32_bits(arg), breadcrumb_base + 16);
	writel_relaxed(upper_32_bits(arg), breadcrumb_base + 20);
	writel_relaxed(lower_32_bits(context), breadcrumb_base + 24);
	writel_relaxed(upper_32_bits(context), breadcrumb_base + 28);
	kexec_breadcrumb_write(stage);
}
EXPORT_SYMBOL_GPL(kexec_breadcrumb_write_detail);

void kexec_rpm_glink_handoff_invalidate(void)
{
	if (!rpm_glink_handoff_base)
		return;

	/* Magic is the publication marker and is always invalidated first. */
	writel_relaxed(0, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, magic));
	writel_relaxed(~KEXEC_RPM_GLINK_HANDOFF_MAGIC,
		       rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, magic_inv));
	wmb();
}
EXPORT_SYMBOL_GPL(kexec_rpm_glink_handoff_invalidate);

int kexec_rpm_glink_handoff_publish(
		const struct kexec_rpm_glink_handoff *record)
{
	struct kexec_rpm_glink_handoff staged;

	if (!rpm_glink_handoff_base)
		return -ENODEV;
	if (!record || record->size != sizeof(*record) ||
	    record->version != KEXEC_RPM_GLINK_HANDOFF_VERSION)
		return -EINVAL;

	staged = *record;
	staged.magic = 0;
	staged.magic_inv = ~KEXEC_RPM_GLINK_HANDOFF_MAGIC;
	staged.state_inv = ~staged.state;

	kexec_rpm_glink_handoff_invalidate();
	memcpy_toio(rpm_glink_handoff_base, &staged, sizeof(staged));
	wmb();

	/* Publish only after every payload field is visible to the next kernel. */
	writel_relaxed(KEXEC_RPM_GLINK_HANDOFF_MAGIC,
		       rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, magic));
	wmb();
	return 0;
}
EXPORT_SYMBOL_GPL(kexec_rpm_glink_handoff_publish);

void kexec_rpm_glink_handoff_set_cpu_state(u32 writer_stage,
		u32 before_mask, u32 after_mask, int result)
{
	if (!rpm_glink_handoff_base)
		return;

	/* Keep the pointer-free handoff record invalid while it is updated. */
	writel_relaxed(0, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, magic));
	wmb();
	writel_relaxed(writer_stage, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, writer_stage));
	writel_relaxed(before_mask, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, reserved[0]));
	writel_relaxed(after_mask, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, reserved[1]));
	writel_relaxed((u32)result, rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, reserved[2]));
	wmb();
	writel_relaxed(KEXEC_RPM_GLINK_HANDOFF_MAGIC,
		       rpm_glink_handoff_base +
		       offsetof(struct kexec_rpm_glink_handoff, magic));
	wmb();
}
EXPORT_SYMBOL_GPL(kexec_rpm_glink_handoff_set_cpu_state);

int kexec_breadcrumb_init(void)
{
	crash_syslog_base = ioremap(XIAOMI_CRASH_SYSLOG_PHYS,
				    XIAOMI_CRASH_BUFFER_SIZE);
	if (!crash_syslog_base)
		return -ENOMEM;
	crash_logbuf_base = ioremap(XIAOMI_CRASH_LOGBUF_PHYS,
				    XIAOMI_CRASH_BUFFER_SIZE);
	if (!crash_logbuf_base) {
		iounmap(crash_syslog_base);
		crash_syslog_base = NULL;
		return -ENOMEM;
	}
	breadcrumb_base = crash_syslog_base + KEXEC_BREADCRUMB_OFFSET;
	rpm_glink_handoff_base = breadcrumb_base +
				 KEXEC_RPM_GLINK_HANDOFF_OFFSET;
	kexec_rpm_glink_handoff_invalidate();

	writel_relaxed(KEXEC_BREADCRUMB_MAGIC, breadcrumb_base + 0);
	writel_relaxed(KEXEC_BREADCRUMB_VERSION, breadcrumb_base + 4);
	writel_relaxed(KEXEC_BREADCRUMB_MAGIC, crash_logbuf_base +
		       XIAOMI_CRASH_HEADER_SIZE + 0);
	writel_relaxed(KEXEC_BREADCRUMB_VERSION, crash_logbuf_base +
		       XIAOMI_CRASH_HEADER_SIZE + 4);
	kexec_breadcrumb_write(0x100);
	xiaomi_crash_buffer_arm(crash_syslog_base);
	xiaomi_crash_buffer_arm(crash_logbuf_base);
	pr_info("kexec breadcrumb armed at physical 0x%llx through Xiaomi crash buffers\n",
		(unsigned long long)KEXEC_BREADCRUMB_PHYS);
	return 0;
}
EXPORT_SYMBOL_GPL(kexec_breadcrumb_init);

void kexec_breadcrumb_exit(void)
{
	if (!crash_syslog_base)
		return;

	/* A normal module unload is a cancellation, not a crash. */
	kexec_rpm_glink_handoff_invalidate();
	writel_relaxed(0, crash_syslog_base);
	writel_relaxed(0, crash_logbuf_base);
	wmb();
	iounmap(crash_syslog_base);
	iounmap(crash_logbuf_base);
	crash_syslog_base = NULL;
	crash_logbuf_base = NULL;
	breadcrumb_base = NULL;
	rpm_glink_handoff_base = NULL;
}
EXPORT_SYMBOL_GPL(kexec_breadcrumb_exit);
