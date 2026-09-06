/*
 * Arch-generic compatibility layer for enabling kexec as loadable kernel
 * module.
 *
 * Copyright (C) 2021 Fabian Mastenbroek.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#define pr_fmt(fmt) "kexec_mod: " fmt

#include <linux/version.h>
#include <linux/mm_types.h>
#include <linux/kexec.h>
#include <linux/kallsyms.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <asm/uaccess.h>
#include <asm/virt.h>

#include "kexec_compat.h"

/* These kernel symbols need to be dynamically resolved at runtime
 * using kallsym due to them not being exposed to kernel modules */
static void (*kernel_restart_prepare_ptr)(char*);
static void (*migrate_to_reboot_cpu_ptr)(void);
static void (*cpu_hotplug_enable_ptr)(void);
static int (*freeze_processes_ptr)(void);
static struct pci_dev *(*pci_get_device_ptr)(unsigned int vendor,
					     unsigned int device,
					     struct pci_dev *from);
static void (*pci_clear_master_ptr)(struct pci_dev *dev);
static int (*pci_wait_for_pending_transaction_ptr)(struct pci_dev *dev);
static int (*pci_read_config_word_ptr)(const struct pci_dev *dev, int where,
				       u16 *val);

void kernel_restart_prepare(char *cmd)
{
	kernel_restart_prepare_ptr(cmd);
}

void migrate_to_reboot_cpu(void)
{
	migrate_to_reboot_cpu_ptr();
}

void cpu_hotplug_enable(void)
{
	cpu_hotplug_enable_ptr();
}

int kexec_freeze_processes(void)
{
	return freeze_processes_ptr();
}

int kexec_quiesce_pci(void)
{
	struct pci_dev *pdev = NULL;
	unsigned int devices = 0;
	unsigned int masters = 0;
	unsigned int unsafe = 0;

	/*
	 * The Xiaomi kernel has CONFIG_KEXEC_CORE disabled.  Consequently,
	 * pci_device_shutdown() was compiled without its kexec-only
	 * pci_clear_master() branch.  A live QCN9224 otherwise keeps doing
	 * direct 64-bit DMA while the next kernel reuses the old kernel's RAM.
	 */
	while ((pdev = pci_get_device_ptr(PCI_ANY_ID, PCI_ANY_ID, pdev))) {
		u16 before = 0xffff;
		u16 after = 0xffff;
		int settled;

		devices++;
		pci_read_config_word_ptr(pdev, PCI_COMMAND, &before);
		if (!(before & PCI_COMMAND_MASTER))
			continue;

		masters++;
		pci_clear_master_ptr(pdev);
		settled = pci_wait_for_pending_transaction_ptr(pdev);
		pci_read_config_word_ptr(pdev, PCI_COMMAND, &after);
		pr_emerg("PCI %s bus master quiesce: command %#06x -> %#06x, pending %s\n",
			 dev_name(&pdev->dev), before, after,
			 settled ? "drained" : "timeout");
		if (after & PCI_COMMAND_MASTER)
			pr_emerg("PCI %s still has bus mastering enabled\n",
				 dev_name(&pdev->dev));
		if (!settled || (after & PCI_COMMAND_MASTER))
			unsafe++;
	}

	pr_emerg("PCI quiesce inspected %u devices, cleared %u bus masters, unsafe %u\n",
		 devices, masters, unsafe);

	return unsafe ? -EBUSY : 0;
}

static void *ksym(const char *name)
{
	return (void *)kallsyms_lookup_name(name);
}

int kexec_compat_load()
{
	if (!(migrate_to_reboot_cpu_ptr = ksym("migrate_to_reboot_cpu"))
	    || !(kernel_restart_prepare_ptr = ksym("kernel_restart_prepare"))
	    || !(cpu_hotplug_enable_ptr = ksym("cpu_hotplug_enable"))
	    || !(freeze_processes_ptr = ksym("freeze_processes"))
	    || !(pci_get_device_ptr = ksym("pci_get_device"))
	    || !(pci_clear_master_ptr = ksym("pci_clear_master"))
	    || !(pci_wait_for_pending_transaction_ptr =
		 ksym("pci_wait_for_pending_transaction"))
	    || !(pci_read_config_word_ptr = ksym("pci_read_config_word")))
		return -ENOENT;
	return 0;
}

void kexec_compat_unload(void)
{}
