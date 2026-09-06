/*
 * Identity paging setup for kexec_mod.
 *
 * Copyright (C) 2021 Fabian Mastenbroek.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#define MODULE_NAME "kexec_mod_arm64"
#define pr_fmt(fmt) MODULE_NAME ": " fmt

#include <linux/errno.h>
#include <linux/interrupt.h>
#include <linux/preempt.h>

#include <asm/pgtable.h>
#include <asm/mmu_context.h>

#include "idmap.h"

#ifdef CONFIG_ARM64_64K_PAGES
#define IDMAP_BLOCK_SHIFT	PAGE_SHIFT
#define IDMAP_BLOCK_SIZE	PAGE_SIZE
#define IDMAP_TABLE_SHIFT	PMD_SHIFT
#else
#define IDMAP_BLOCK_SHIFT	SECTION_SHIFT
#define IDMAP_BLOCK_SIZE	SECTION_SIZE
#define IDMAP_TABLE_SHIFT	PUD_SHIFT
#endif

#define block_index(addr) (((addr) >> IDMAP_BLOCK_SHIFT) & (PTRS_PER_PTE - 1))
#define block_align(addr) (((addr) >> IDMAP_BLOCK_SHIFT) << IDMAP_BLOCK_SHIFT)

/*
 * Initial memory map attributes.
 */
#ifndef CONFIG_SMP
#define PTE_FLAGS	PTE_TYPE_PAGE | PTE_AF
#define PMD_FLAGS	PMD_TYPE_SECT | PMD_SECT_AF
#else
#define PTE_FLAGS	PTE_TYPE_PAGE | PTE_AF | PTE_SHARED
#define PMD_FLAGS	PMD_TYPE_SECT | PMD_SECT_AF | PMD_SECT_S
#endif

#ifdef CONFIG_ARM64_64K_PAGES
#define MM_MMUFLAGS	PTE_ATTRINDX(MT_NORMAL) | PTE_FLAGS
#else
#define MM_MMUFLAGS	PMD_ATTRINDX(MT_NORMAL) | PMD_FLAGS
#endif

pgd_t kexec_idmap_pg_dir[PTRS_PER_PGD] __attribute__ ((aligned (4096)));
pte_t kexec_idmap_pt[2 * PTRS_PER_PTE] __attribute__ ((aligned (4096)));
static pgd_t kexec_reserved_pg_dir[PTRS_PER_PGD]
	__attribute__ ((aligned (4096)));

extern void __cpu_soft_restart(unsigned el2_switch,
	unsigned long entry, unsigned long arg0, unsigned long arg1,
	unsigned long arg2);
extern unsigned long kexec_idmap_probe_phys(void);

int kexec_idmap_setup(void)
{
	int i;
	unsigned long pa, pdx;
	pte_t *pmd, *next_pmd = kexec_idmap_pt;
	void *ptrs[] = {kexec_idmap_pg_dir,
			 kexec_idmap_pt,
			 kexec_idmap_pt + PTRS_PER_PTE,
			 __cpu_soft_restart,
			 kexec_idmap_probe_phys};

	/* Clear the idmap page table */
	memset(kexec_idmap_pg_dir, 0, sizeof(kexec_idmap_pg_dir));
	memset(kexec_idmap_pt, 0, sizeof(kexec_idmap_pt));
	memset(kexec_reserved_pg_dir, 0, sizeof(kexec_reserved_pg_dir));

	for (i = 0; i < ARRAY_SIZE(ptrs); i++) {
		pa = kexec_pa_symbol(ptrs[i]);
		if (!pa) {
			pr_err("Cannot resolve idmap pointer %d (%px)\n",
			       i, ptrs[i]);
			return -EFAULT;
		}
		pr_info("idmap pointer %d: va=%px pa=0x%lx pgd=%lu block=%lu\n",
			i, ptrs[i], pa, pgd_index(pa), block_index(pa));
		pdx = pgd_index(pa);

		if (pgd_val(kexec_idmap_pg_dir[pdx])) {
			pmd = (void *) phys_to_virt(pgd_val(kexec_idmap_pg_dir[pdx]) & ~0xFFF);
		} else {
			if (next_pmd >= kexec_idmap_pt + ARRAY_SIZE(kexec_idmap_pt)) {
				pr_err("More physical PGD regions than idmap tables\n");
				return -E2BIG;
			}
			pr_info("Created new idmap page table for 0x%lx\n", pa);

			pmd = next_pmd;
			next_pmd += PTRS_PER_PTE;
			kexec_idmap_pg_dir[pdx] = __pgd(kexec_pa_symbol(pmd) | PMD_TYPE_TABLE);
		}

		pmd[block_index(pa)] = __pte(block_align(pa) | MM_MMUFLAGS);
	}

	return 0;
}

void kexec_idmap_install(void)
{
	/*
	 * The kernel's reserved_pg_dir is not exported to modules. Use an
	 * equivalent empty table owned by this module while replacing TTBR0.
	 */
	write_sysreg(phys_to_ttbr(kexec_pa_symbol(kexec_reserved_pg_dir)),
		     ttbr0_el1);
	isb();
	local_flush_tlb_all();
	cpu_set_idmap_tcr_t0sz();

	cpu_do_switch_mm(kexec_pa_symbol(kexec_idmap_pg_dir), &init_mm);
}

int kexec_idmap_selftest(void)
{
	typedef unsigned long (*probe_fn_t)(void);
	unsigned long flags, probe_pa, result;
	u64 old_tcr, old_ttbr0, old_ttbr1;

	probe_pa = kexec_pa_symbol(kexec_idmap_probe_phys);
	if (!probe_pa)
		return -EFAULT;

	preempt_disable();
	local_irq_save(flags);
	old_tcr = read_sysreg(tcr_el1);
	old_ttbr0 = read_sysreg(ttbr0_el1);
	old_ttbr1 = read_sysreg(ttbr1_el1);

	kexec_idmap_install();
	result = ((probe_fn_t)probe_pa)();

	/* Return to the exact translation state present before the probe. */
	write_sysreg(phys_to_ttbr(kexec_pa_symbol(kexec_reserved_pg_dir)),
		     ttbr0_el1);
	isb();
	local_flush_tlb_all();
	write_sysreg(old_tcr, tcr_el1);
	isb();
	write_sysreg(old_ttbr1, ttbr1_el1);
	isb();
	write_sysreg(old_ttbr0, ttbr0_el1);
	isb();
	local_flush_tlb_all();

	local_irq_restore(flags);
	preempt_enable();

	if (result != 0x6b78UL) {
		pr_err("idmap self-test returned 0x%lx instead of 0x6b78\n",
		       result);
		return -EIO;
	}

	pr_info("idmap self-test passed at physical entry 0x%lx\n", probe_pa);
	return 0;
}

/**
 * Resolve the physical address of the specified pointer.
 * We cannot use __pa_symbol for symbols defined in our kernel module, so we need to walk
 * the page manually.
 */
phys_addr_t kexec_pa_symbol(void *ptr)
{
	unsigned long va = (unsigned long) ptr;
	unsigned long page_offset;
	pgd_t *pgd;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *ptep, pte;
	struct page *page = NULL;

	pgd = pgd_offset_k(va);
	if (pgd_none(*pgd) || pgd_bad(*pgd)) {
		return 0;
	}

	pud = pud_offset(pgd , va);
	if (pud_none(*pud) || pud_bad(*pud)) {
		return 0;
	}

	pmd = pmd_offset(pud, va);
	if (pmd_none(*pmd) || pmd_bad(*pmd)) {
		return 0;
	}

	ptep = pte_offset_map(pmd, va);
	if (!ptep) {
		return 0;
	}

	pte = *ptep;
	pte_unmap(ptep);
	page = pte_page(pte);
	page_offset = va & ~PAGE_MASK;
	return page_to_phys(page) | page_offset;
}
