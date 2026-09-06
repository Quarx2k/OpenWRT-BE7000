// SPDX-License-Identifier: GPL-2.0
/* Carry powered secondary CPUs into the replacement kernel via spin-table. */

#define MODULE_NAME "kexec_mod_arm64"
#define pr_fmt(fmt) MODULE_NAME ": " fmt

#include <linux/cpu.h>
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/smp.h>

#include <asm/daifflags.h>

#include "cpu-reset.h"
#include "secondary_park.h"

extern const u8 kexec_secondary_park_blob_start[];
extern const u8 kexec_secondary_park_blob_end[];

static void __iomem *secondary_park_window;
static bool secondary_park_ready;
static bool secondary_park_done;

static void __iomem *secondary_release_addr(void)
{
	return secondary_park_window +
		(KEXEC_SECONDARY_RELEASE_PHYS - KEXEC_SECONDARY_PARK_CODE_PHYS);
}

static void __iomem *secondary_ack_addr(unsigned int cpu)
{
	return secondary_park_window +
		(KEXEC_SECONDARY_ACK_PHYS - KEXEC_SECONDARY_PARK_CODE_PHYS) +
		cpu * KEXEC_SECONDARY_ACK_STRIDE;
}

static void kexec_secondary_park_ipi(void *unused)
{
	unsigned int cpu = raw_smp_processor_id();
	phys_addr_t ack_phys = KEXEC_SECONDARY_ACK_PHYS +
		cpu * KEXEC_SECONDARY_ACK_STRIDE;

	local_daif_mask();

	/* Do not execute a stale instruction line left by an earlier boot. */
	asm volatile("ic iallu\n\tdsb sy\n\tisb" : : : "memory");

	cpu_soft_restart(KEXEC_SECONDARY_PARK_CODE_PHYS,
			 KEXEC_SECONDARY_RELEASE_PHYS, ack_phys,
			 KEXEC_SECONDARY_HOLDING_PEN_PHYS);
}

static unsigned long kexec_secondary_ack_mask(unsigned long target_mask)
{
	unsigned long mask = 0;
	unsigned int cpu;

	for_each_set_bit(cpu, &target_mask, BITS_PER_LONG) {
		void __iomem *ack = secondary_ack_addr(cpu);
		u32 stage = readl_relaxed(ack);
		u32 stage_inv = readl_relaxed(ack + 4);
		u64 mpidr = readq_relaxed(ack + 8);

		if (stage == KEXEC_SECONDARY_STAGE_PARKED &&
		    stage_inv == ~KEXEC_SECONDARY_STAGE_PARKED &&
		    (mpidr & 0xff) == cpu)
			mask |= BIT(cpu);
	}

	return mask;
}

int kexec_secondary_park_prepare(void)
{
	size_t blob_size = kexec_secondary_park_blob_end -
		kexec_secondary_park_blob_start;
	size_t i;

	if (!secondary_park_window || !secondary_park_ready)
		return -ENODEV;
	if (!blob_size || blob_size > 0x400)
		return -E2BIG;

	secondary_park_done = false;
	writeq_relaxed(0, secondary_release_addr());
	for (i = 0; i < NR_CPUS; i++)
		memset_io(secondary_ack_addr(i), 0,
			  sizeof(struct kexec_secondary_ack));
	memcpy_toio(secondary_park_window, kexec_secondary_park_blob_start,
		    blob_size);
	wmb();

	for (i = 0; i < blob_size; i++) {
		if (readb_relaxed(secondary_park_window + i) !=
		    kexec_secondary_park_blob_start[i])
			return -EIO;
	}

	return 0;
}
EXPORT_SYMBOL_GPL(kexec_secondary_park_prepare);

int kexec_secondary_park_cpus(unsigned long expected_online_mask,
			      unsigned long *parked_mask)
{
	unsigned long target_mask = expected_online_mask & ~BIT(0);
	unsigned long seen = 0;
	unsigned int cpu;
	int ret;

	if (!secondary_park_ready || !target_mask ||
	    raw_smp_processor_id() != 0)
		return -EINVAL;
	if (cpumask_bits(cpu_online_mask)[0] != expected_online_mask)
		return -EBUSY;

	pr_emerg("Handing secondary CPUs %#lx to physical spin-table at %#llx\n",
		 target_mask,
		 (unsigned long long)KEXEC_SECONDARY_RELEASE_PHYS);

	for_each_set_bit(cpu, &target_mask, BITS_PER_LONG) {
		ret = smp_call_function_single(cpu, kexec_secondary_park_ipi,
					       NULL, false);
		if (ret)
			return ret;
	}

	/*
	 * No timeout is intentional.  Once one CPU has left the old kernel it
	 * cannot be resumed safely.  If another CPU never acknowledges, the
	 * already armed stock watchdog recovers through the normal NAND boot.
	 */
	while (seen != target_mask) {
		seen = kexec_secondary_ack_mask(target_mask);
		cpu_relax();
	}

	secondary_park_done = true;
	if (parked_mask)
		*parked_mask = seen;

	return 0;
}
EXPORT_SYMBOL_GPL(kexec_secondary_park_cpus);

bool kexec_secondary_park_complete(void)
{
	return secondary_park_done;
}
EXPORT_SYMBOL_GPL(kexec_secondary_park_complete);

int kexec_secondary_park_init(void)
{
	secondary_park_window = ioremap(KEXEC_SECONDARY_PARK_CODE_PHYS,
					KEXEC_SECONDARY_PARK_WINDOW_SIZE);
	if (!secondary_park_window)
		return -ENOMEM;

	secondary_park_ready = true;
	if (kexec_secondary_park_prepare()) {
		iounmap(secondary_park_window);
		secondary_park_window = NULL;
		secondary_park_ready = false;
		return -EIO;
	}

	pr_info("secondary spin-table handoff prepared at physical %#llx\n",
		(unsigned long long)KEXEC_SECONDARY_PARK_CODE_PHYS);
	return 0;
}

void kexec_secondary_park_exit(void)
{
	if (!secondary_park_window)
		return;

	writeq_relaxed(0, secondary_release_addr());
	wmb();
	iounmap(secondary_park_window);
	secondary_park_window = NULL;
	secondary_park_ready = false;
	secondary_park_done = false;
}
