/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Physical holding loop for a secondary CPU carried across kexec.
 *
 * x0: little-endian spin-table release address
 * x1: this CPU's persistent acknowledgement record
 * x2: exact replacement-kernel secondary_holding_pen physical address
 *
 * Entry is through __cpu_soft_restart, with the MMU and EL1 caches disabled.
 * The HYP_SOFT_RESTART path leaves the CPU at EL2 when EL2 is available, which
 * is also the entry level expected by the replacement kernel's holding pen.
 */

#include <linux/linkage.h>

	.text
	.balign 64

ENTRY(kexec_secondary_park_blob_start)
	msr	daifset, #0xf
	mrs	x3, mpidr_el1
	mov	w4, #0x5601
	str	w4, [x1]
	mvn	w5, w4
	str	w5, [x1, #4]
	str	x3, [x1, #8]
	str	xzr, [x1, #16]
	dc	civac, x1
	dsb	sy
	sev

1:	dc	ivac, x0
	dsb	sy
	ldr	x4, [x0]
	cmp	x4, x2
	b.eq	2f
	wfe
	b	1b

2:	str	x4, [x1, #16]
	mov	w5, #0x5602
	str	w5, [x1]
	mvn	w6, w5
	str	w6, [x1, #4]
	dc	civac, x1
	dsb	sy
	ic	iallu
	dsb	sy
	isb
	br	x4
ENDPROC(kexec_secondary_park_blob_start)

	.global kexec_secondary_park_blob_end
kexec_secondary_park_blob_end:
