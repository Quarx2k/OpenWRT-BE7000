/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __QCOM_GLINK_BE7000_H__
#define __QCOM_GLINK_BE7000_H__

#include <linux/build_bug.h>
#include <linux/io.h>
#include <linux/string.h>

#define BE7000_RGLH_PHYS		0x4fb3f300ULL
#define BE7000_RGLH_MAGIC		0x484c4752U
#define BE7000_RGLH_READY		1U
#define BE7000_RGLH_INJECTED	2U
#define BE7000_RGLH_ADOPTED	3U
#define BE7000_RGLH_NAME		"rpm_requests"

/* Exact v62 wire format: little-endian ARM64, no kernel pointers. */
struct be7000_rpm_record {
	u32 magic, magic_inv;
	u16 version, size;
	u32 state, state_inv;
	u32 flags, lcid, rcid;
	u64 features;
	u32 tx_head, tx_tail, rx_head, rx_tail;
	u32 tx_len, rx_len;
	char name[16];
	u32 writer_stage, reserved[3];
};

/* Receiver-owned object; only record is shared with the old kernel. */
struct be7000_rpm_handoff {
	struct be7000_rpm_record record;
	void __iomem *base;
};

static inline bool be7000_rpm_record_valid(const struct be7000_rpm_record *r)
{
	BUILD_BUG_ON(sizeof(*r) != 96);
	BUILD_BUG_ON(offsetof(struct be7000_rpm_record, state) != 12);
	BUILD_BUG_ON(offsetof(struct be7000_rpm_record, features) != 32);
	BUILD_BUG_ON(offsetof(struct be7000_rpm_record, name) != 64);
	BUILD_BUG_ON(offsetof(struct be7000_rpm_record, writer_stage) != 80);

	return r->magic == BE7000_RGLH_MAGIC && r->magic_inv == ~r->magic &&
		r->version == 1 && r->size == sizeof(*r) &&
		r->state == BE7000_RGLH_READY && r->state_inv == ~r->state &&
		(r->flags & 1) && r->lcid && r->lcid < 65536 &&
		r->rcid && r->rcid < 65536 &&
		!memcmp(r->name, BE7000_RGLH_NAME "\0\0\0", sizeof(r->name)) &&
		r->tx_head == r->tx_tail && r->rx_head == r->rx_tail &&
		!(r->tx_head & 7) && !(r->rx_tail & 7) &&
		r->tx_head < r->tx_len && r->rx_tail < r->rx_len;
}

static inline void be7000_rpm_set_state(struct be7000_rpm_handoff *h, u32 state)
{
	writel_relaxed(~state, h->base +
		       offsetof(struct be7000_rpm_record, state_inv));
	wmb();
	writel_relaxed(state, h->base +
		       offsetof(struct be7000_rpm_record, state));
	wmb();
	h->record.state = state;
	h->record.state_inv = ~state;
}

#endif
