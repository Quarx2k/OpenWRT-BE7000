// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2016-2018 Linaro Ltd.
 * Copyright (C) 2014 Sony Mobile Communications AB
 * Copyright (c) 2012-2018, 2021 The Linux Foundation. All rights reserved.
 */
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of_address.h>
#include <linux/of_device.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/reset.h>
#include <linux/soc/qcom/mdt_loader.h>
#include <linux/soc/qcom/smem.h>
#include <linux/soc/qcom/smem_state.h>
#include <linux/qcom_scm.h>
#include <linux/interrupt.h>
#include <linux/kthread.h>
#ifdef CONFIG_IPQ_SUBSYSTEM_RAMDUMP
#include <soc/qcom/ramdump.h>
#endif
#include "qcom_common.h"
#include "qcom_q6v5.h"

#define WCSS_CRASH_REASON		421
#define WCSS_SMEM_HOST			1

#define Q6_BOOT_TRIG_SVC_ID		0x5
#define Q6_BOOT_TRIG_CMD_ID		0x2

/* Q6SS Register Offsets */
#define Q6SS_RESET_REG			0x014
#define Q6SS_DBG_CFG                    0x018
#define Q6SS_GFMUX_CTL_REG		0x020
#define Q6SS_PWR_CTL_REG		0x030
#define Q6SS_MEM_PWR_CTL		0x0B0
#define Q6SS_STRAP_ACC			0x110
#define Q6SS_CGC_OVERRIDE		0x034
#define Q6SS_BCR_REG			0x6000
#define Q6SS_BOOT_CORE_START		0x400
#define Q6SS_BOOT_CMD                   0x404
#define Q6SS_BOOT_STATUS		0x408
#define Q6SS_AHB_UPPER			0x104
#define Q6SS_AHB_LOWER			0x108

/* AXI Halt Register Offsets */
#define AXI_HALTREQ_REG			0x0
#define AXI_HALTACK_REG			0x4
#define AXI_IDLE_REG			0x8

#define HALT_ACK_TIMEOUT_MS		100
#define MST_SLV_BDG_ACK_TIMEOUT_US	10000

/* Q6SS_RESET */
#define Q6SS_STOP_CORE			BIT(0)
#define Q6SS_CORE_ARES			BIT(1)
#define Q6SS_BUS_ARES_ENABLE		BIT(2)

/* Q6SS_BRC_RESET */
#define Q6SS_BRC_BLK_ARES		BIT(0)

/* Q6SS_GFMUX_CTL */
#define Q6SS_CLK_ENABLE			BIT(1)
#define Q6SS_SWITCH_CLK_SRC		BIT(8)

/* Q6SS_PWR_CTL */
#define Q6SS_L2DATA_STBY_N		BIT(18)
#define Q6SS_SLP_RET_N			BIT(19)
#define Q6SS_CLAMP_IO			BIT(20)
#define QDSS_BHS_ON			BIT(21)
#define QDSS_Q6_MEMORIES		GENMASK(15, 0)

/* Q6SS parameters */
#define Q6SS_LDO_BYP		BIT(25)
#define Q6SS_BHS_ON		BIT(24)
#define Q6SS_CLAMP_WL		BIT(21)
#define Q6SS_CLAMP_QMC_MEM		BIT(22)
#define HALT_CHECK_MAX_LOOPS		20000
#define Q6SS_XO_CBCR		GENMASK(5, 3)
#define Q6SS_SLEEP_CBCR		GENMASK(5, 2)
#define Q6SS_CORE_CBCR         BIT(5)
#define Q6SS_TIMEOUT_US         1000
#define MSIP_TIMEOUT_US         1

/* Q6SS config/status registers */
#define TCSR_GLOBAL_CFG0	0x0
#define TCSR_GLOBAL_CFG1	0x4
#define SSCAON_CONFIG		0x8
#define SSCAON_STATUS		0xc
#define Q6SS_BHS_STATUS		0x78
#define Q6SS_RST_EVB		0x10

#define BHS_EN_REST_ACK		BIT(0)
#define WCSS_HM_RET		BIT(1)
#define SSCAON_ENABLE		BIT(13)
#define SSCAON_BUS_EN		BIT(15)
#define SSCAON_BUS_MUX_MASK	GENMASK(18, 16)
#define SSCAON_MASK             GENMASK(17, 15)

#define MEM_BANKS		19
#define TCSR_WCSS_CLK_MASK	0x1F
#define TCSR_WCSS_CLK_ENABLE	0x14

#define MAX_HALT_REG		4

#define WCNSS_PAS_ID		6
#define MPD_WCNSS_PAS_ID        0xD
#define MAX_SEGMENTS		10

#define BUF_SIZE 35
#define REMOTE_PID	1
#define VERSION 1
#define Q6_BOOT_ARGS_SMEM_SIZE 4096

#define AXIS_CBCR		0x60
#define DBG_IFC_APB_BDG_CBCR	0x48
#define DBG_IFC_NTS_CBCR	0x40
#define DBG_IFC_ATB_CBCR	0x3c
#define ECAHB_CBCR		0x58
#define DBG_IFC_ATB_BDG_CBCR	0x4c
#define DBG_IFC_APB_CBCR	0x38
#define AXIM_CBCR		0x5c
#define DBG_IFC_NTS_BDG_CBCR	0x50
#define Q6_TSCTR_1TO2_CBCR	0x20
#define Q6SS_TRIG_CBCR		0xa0
#define Q6_AXIS_CBCR		0x10
#define Q6_AHB_S_CBCR		0x18
#define Q6SS_ATBM_CBCR		0x1c
#define Q6_AHB_CBCR		0x14
#define Q6_AXIM_CBCR		0x0c
#define Q6SS_PCLKDBG_CBCR	0x24
#define SYS_NOC_WCSS_AHB_CBCR	0x9030
#define WCSS_SLV_ASYNC_BDG_CBCR	0x90b4
#define WCSS_MST_ASYNC_BDG_CBCR	0x90b0
#define CE_AXI_CBCR		0x68
#define CE_PCNOC_AHB_CBCR	0x70
#define CE_AHB_CBCR		0x74
#define CLK_ON			0x1
#define CLK_OFF			BIT(31)

#define Q6_PWR_DBG_CTRL		0x200c
#define MST_BDG_RESET_ACK	0x4
#define SLV_BDG_RESET_REQ	0x8
#define SLV_BDG_RESET_ACK	0xc

static const struct wcss_data q6_devsoc_res_init;
static int debug_wcss;

/**
 * enum state - state of a wcss (private)
 * @WCSS_NORMAL: subsystem is operating normally
 * @WCSS_CRASHED: subsystem has crashed and hasn't been shutdown
 * @WCSS_RESTARTING: subsystem has been shutdown and is now restarting
 * @WCSS_SHUTDOWN: subsystem has been shutdown
 *
 */
enum q6_wcss_state {
	WCSS_NORMAL,
	WCSS_CRASHED,
	WCSS_RESTARTING,
	WCSS_SHUTDOWN,
};

enum {
	Q6_IPQ,
	WCSS_AHB_IPQ,
	WCSS_PCIE_IPQ,
};

enum q6_version {
	Q6V5,
	Q6V6,
	Q6V7,
};

struct q6_wcss {
	struct device *dev;

	void __iomem *reg_base;
	void __iomem *rmb_base;
	void __iomem *tcsr_msip_base;
	void __iomem *tcsr_q6_base;
	void __iomem *ce_ahb_base;
	void __iomem *qtimer_base;

	struct regmap *halt_map;
	u32 halt_q6;
	u32 halt_wcss;
	u32 halt_nc;
	u32 reset_cmd_id;

	struct clk *xo;
	struct clk *ahbfabric_cbcr_clk;
	struct clk *gcc_abhs_cbcr;			//"gcc_wcss_ahb_s_clk"
	struct clk *gcc_axim_cbcr;			//"gcc_q6_axim_clk"
	struct clk *lcc_csr_cbcr;
	struct clk *ahbs_cbcr;				//"gcc_q6_ahb_s_clk"
	struct clk *tcm_slave_cbcr;
	struct clk *qdsp6ss_abhm_cbcr;			//"gcc_q6_ahb_clk"
	struct clk *qdsp6ss_sleep_cbcr;
	struct clk *qdsp6ss_axim_cbcr;			//"gcc_wcss_axi_m_clk"
	struct clk *qdsp6ss_xo_cbcr;
	struct clk *qdsp6ss_core_gfmux;
	struct clk *lcc_bcr_sleep;
	struct clk *prng_clk;
	struct clk *eachb_clk;				//"gcc_wcss_ecahb_clk"
	struct clk *acmt_clk;				//"gcc_wcss_acmt_clk"
	struct clk *gcc_axim2_clk;			//"gcc_q6_axim2_clk"
	struct clk *axmis_clk;				//"gcc_q6_axis_clk"
	struct clk *axi_s_clk;				//"gcc_wcss_axi_s_clk"
	struct clk *gcc_q6_tsctr_1to2_clk;
	struct clk *gcc_q6ss_trig_clk;
	struct clk *gcc_q6ss_atbm_clk;
	struct clk *gcc_q6ss_pclkdbg_clk;
	struct clk *dbg_apb_bdg_clk;
	struct clk *dbg_nts_clk;
	struct clk *dbg_atb_clk;
	struct clk *dbg_atb_bdg_clk;
	struct clk *dbg_apb_clk;
	struct clk *dbg_nts_bdg_clk;
	struct clk *gcc_sys_noc_wcss_ahb_clk;
	struct clk *gcc_ce_axi_clk;
	struct clk *gcc_ce_pcnoc_ahb_clk;
	struct clk *gcc_ce_ahb_clk;

	struct qcom_rproc_glink glink_subdev;
	struct qcom_rproc_ssr ssr_subdev;
	struct qcom_sysmon *sysmon;

	struct reset_control *wcss_aon_reset;
	struct reset_control *wcss_reset;
	struct reset_control *wcss_q6_reset;
	struct reset_control *ce_reset;

	struct qcom_q6v5 q6;

	phys_addr_t mem_phys;
	phys_addr_t mem_reloc;
	void *mem_region;
	size_t mem_size;

	int crash_reason_smem;
	u32 version;
	bool requires_force_stop;
	bool need_mem_protection;
	u8 pd_asid;
	enum q6_wcss_state state;
	bool backdoor;
	bool is_emulation;
};

struct wcss_data {
	int (*init_clock)(struct q6_wcss *wcss);
	int (*init_irq)(struct qcom_q6v5 *q6, struct platform_device *pdev,
				struct rproc *rproc, int remote_id,
				int crash_reason,
				void (*handover)(struct qcom_q6v5 *q6));
	const char *q6_firmware_name;
	int crash_reason_smem;
	int remote_id;
	u32 version;
	u32 reset_cmd_id;
	bool aon_reset_required;
	bool wcss_q6_reset_required;
	bool wcss_reset_required;
	bool ce_reset_required;
	const char *ssr_name;
	const char *sysmon_name;
	int ssctl_id;
	const struct rproc_ops *ops;
	bool requires_force_stop;
	bool need_mem_protection;
	bool need_auto_boot;
	bool glink_subdev_required;
	u8 pd_asid;
	bool reset_seq;
	enum q6_version q6ver;
};

static int qcom_get_pd_fw_info(struct q6_wcss *wcss, const struct firmware *fw,
				struct ramdump_segment *segs, int index,
				struct qcom_pd_fw_info *fw_info)
{
	int ret = get_pd_fw_info(wcss->dev, fw, wcss->mem_phys, wcss->mem_size,
			wcss->pd_asid, fw_info);
	if (ret) {
		dev_err(wcss->dev, "couldn't get PD firmware info : %d\n", ret);
		return ret;
	}

	segs[index].address = fw_info->paddr;
	segs[index].size = fw_info->size;
	segs[index].v_address = ioremap(segs[index].address,
			segs[index].size);
	segs[index].vaddr = fw_info->vaddr;
	return ret;
}

#ifdef CONFIG_IPQ_SUBSYSTEM_RAMDUMP
static void crashdump_init(struct rproc *rproc,
				struct rproc_dump_segment *segment,
				void *dest)
{
	void *handle;
	struct ramdump_segment segs[MAX_SEGMENTS];
	int ret, index = 0;
	struct qcom_pd_fw_info fw_info = {0};
	struct q6_wcss *wcss = rproc->priv;
	struct device *dev = wcss->dev;
	struct device_node *node = NULL, *np = dev->of_node, *upd_np;
	const struct firmware *fw;
	char dev_name[BUF_SIZE];
	u32 temp;

	/*
	 * Send ramdump notification to userpd(s) if rootpd
	 * crashed, irrespective of userpd status.
	 */
	for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
		struct platform_device *upd_pdev;
		struct rproc *upd_rproc;

		if (strstr(upd_np->name, "pd") == NULL)
			continue;
		upd_pdev = of_find_device_by_node(upd_np);
		upd_rproc = platform_get_drvdata(upd_pdev);
		rproc_subsys_notify(upd_rproc,
				SUBSYS_RAMDUMP_NOTIFICATION, false);
	}

	if (wcss->pd_asid)
		snprintf(dev_name, BUF_SIZE, "q6v5_wcss_userpd%d_mem",
							wcss->pd_asid);
	else
		snprintf(dev_name, BUF_SIZE, "q6mem");

	handle = create_ramdump_device(dev_name, &rproc->dev);
	if (!handle) {
		dev_err(&rproc->dev, "unable to create ramdump device"
						"for %s\n", rproc->name);
		return;
	}

	if (create_ramdump_device_file(handle)) {
		dev_err(&rproc->dev, "unable to create ramdump device"
						"for %s\n", rproc->name);
		goto free_device;
	}

	while (index < MAX_SEGMENTS) {
		node = of_parse_phandle(np, "memory-region", index);
		if (!node)
			break;

		ret = of_property_read_u32_index(node, "reg", 1, &temp);
		if (ret) {
			pr_err("Could not retrieve reg addr %d\n", ret);
			of_node_put(node);
			goto put_node;
		}
		segs[index].address = (u32)temp;

		ret = of_property_read_u32_index(node, "reg", 3, &temp);
		if (ret) {
			pr_err("Could not retrieve reg size %d\n", ret);
			of_node_put(node);
			goto put_node;
		}
		segs[index].size = (u32)temp;

		segs[index].v_address = ioremap(segs[index].address,
						segs[index].size);
		of_node_put(node);
		index++;
	}

	/* Get the PD firmware info */
	ret = request_firmware(&fw, rproc->firmware, dev);
	if (ret < 0) {
		dev_err(dev, "request_firmware failed: %d\n", ret);
		goto free_device;
	}

	if (wcss->pd_asid) {
		ret = qcom_get_pd_fw_info(wcss, fw, segs, index, &fw_info);
		if (ret)
			goto free_device;
		index++;
	}
	wcss->state = WCSS_RESTARTING;

	release_firmware(fw);
	do_elf_ramdump(handle, segs, index);
put_node:
	of_node_put(np);
free_device:
	destroy_ramdump_device(handle);
}
#else
static void crashdump_init(struct rproc *rproc,
				struct rproc_dump_segment *segment, void *dest)
{
}
#endif

static int ipq5018_clks_prepare_enable(struct q6_wcss *wcss)
{
	int ret;

	ret = clk_prepare_enable(wcss->gcc_abhs_cbcr);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->eachb_clk);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->acmt_clk);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->gcc_axim_cbcr);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->qdsp6ss_axim_cbcr);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->gcc_axim2_clk);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->qdsp6ss_abhm_cbcr);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->ahbs_cbcr);
	if (ret)
		return ret;

	ret = clk_prepare_enable(wcss->axi_s_clk);
	if (ret)
		return ret;

	return 0;
}

static void ipq5018_clks_prepare_disable(struct q6_wcss *wcss)
{
	clk_disable_unprepare(wcss->gcc_abhs_cbcr);
	clk_disable_unprepare(wcss->eachb_clk);
	clk_disable_unprepare(wcss->acmt_clk);
	clk_disable_unprepare(wcss->gcc_axim_cbcr);
	clk_disable_unprepare(wcss->qdsp6ss_axim_cbcr);
	clk_disable_unprepare(wcss->gcc_axim2_clk);
	clk_disable_unprepare(wcss->qdsp6ss_abhm_cbcr);
	clk_disable_unprepare(wcss->ahbs_cbcr);
	clk_disable_unprepare(wcss->axi_s_clk);
}

void disable_devsoc_wcss_clocks(struct q6_wcss *wcss)
{
	int loop;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);
	struct q6_wcss *rpd_wcss = rpd_rproc->priv;

	/* wcss clocks */
	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_APB_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_APB_BDG_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_NTS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_NTS_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + AXIS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + AXIS_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_ATB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_ATB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_ATB_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_ATB_BDG_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_APB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_APB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + AXIM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + AXIM_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + DBG_IFC_NTS_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_NTS_BDG_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + WCSS_SLV_ASYNC_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + WCSS_SLV_ASYNC_BDG_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + WCSS_MST_ASYNC_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + WCSS_MST_ASYNC_BDG_CBCR) == CLK_OFF)
			break;
	}

	/* ce clocks */
	writel(0x0, rpd_wcss->ce_ahb_base + CE_AXI_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_AXI_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + CE_PCNOC_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_PCNOC_AHB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, rpd_wcss->ce_ahb_base + CE_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_AHB_CBCR) == CLK_OFF)
			break;
	}
}

void disable_devsoc_clocks(struct q6_wcss *wcss)
{
	int loop;

	writel(0x0, wcss->ce_ahb_base + ECAHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + ECAHB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + SYS_NOC_WCSS_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + SYS_NOC_WCSS_AHB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6_TSCTR_1TO2_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_TSCTR_1TO2_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6SS_TRIG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_TRIG_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6_AXIS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AXIS_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6_AHB_S_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AHB_S_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6SS_ATBM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_ATBM_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AHB_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6_AXIM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AXIM_CBCR) == CLK_OFF)
			break;
	}

	writel(0x0, wcss->ce_ahb_base + Q6SS_PCLKDBG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_PCLKDBG_CBCR) == CLK_OFF)
			break;
	}
}

int enable_devsoc_wcss_clocks(struct q6_wcss *wcss)
{
	int loop;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);
	struct q6_wcss *rpd_wcss = rpd_rproc->priv;

	/* wcss clocks */
	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_APB_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_APB_BDG_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_NTS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_NTS_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + AXIS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + AXIS_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_ATB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_ATB_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_ATB_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_ATB_BDG_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_APB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_APB_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + AXIM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + AXIM_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + DBG_IFC_NTS_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + DBG_IFC_NTS_BDG_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + WCSS_SLV_ASYNC_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + WCSS_SLV_ASYNC_BDG_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + WCSS_MST_ASYNC_BDG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + WCSS_MST_ASYNC_BDG_CBCR) == CLK_ON)
			break;
	}

	/* ce clocks */
	writel(0x1, rpd_wcss->ce_ahb_base + CE_AXI_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_AXI_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + CE_PCNOC_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_PCNOC_AHB_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, rpd_wcss->ce_ahb_base + CE_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(rpd_wcss->ce_ahb_base + CE_AHB_CBCR) == CLK_ON)
			break;
	}

	return 0;
}

int enable_devsoc_clocks(struct q6_wcss *wcss)
{
	int ret, loop = 0;

	ret = reset_control_assert(wcss->wcss_q6_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_q6_reset assert failed\n");
		return ret;
	}

	writel(0x0, wcss->ce_ahb_base + AXIS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + AXIS_CBCR) == CLK_OFF)
			break;
	}

	ret = reset_control_deassert(wcss->wcss_q6_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_q6_reset deassert failed\n");
		return ret;
	}

	writel(0x1, wcss->ce_ahb_base + ECAHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + ECAHB_CBCR) == CLK_ON)
			break;
	}

	/* Q6SS clocks */
	writel(0x1, wcss->ce_ahb_base + Q6_TSCTR_1TO2_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_TSCTR_1TO2_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6SS_TRIG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_TRIG_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6_AXIS_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AXIS_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6_AHB_S_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AHB_S_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6SS_ATBM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_ATBM_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AHB_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6_AXIM_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6_AXIM_CBCR) == CLK_ON)
			break;
	}

	writel(0x1, wcss->ce_ahb_base + Q6SS_PCLKDBG_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + Q6SS_PCLKDBG_CBCR) == CLK_ON)
			break;
	}

	/*2. Deassert AON Reset */
	ret = reset_control_deassert(wcss->wcss_aon_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_aon_reset failed\n");
		return ret;
	}

	loop = 0;
	while (loop < 2000) {
		mdelay(1);
		loop++;
	}

	writel(0x1, wcss->ce_ahb_base + SYS_NOC_WCSS_AHB_CBCR);
	for (loop = 0; loop < 10; loop++) {
		udelay(1);
		if (readl(wcss->ce_ahb_base + SYS_NOC_WCSS_AHB_CBCR) == CLK_ON)
			break;
	}

	return 0;
}

static int q6v7_wcss_reset(struct q6_wcss *wcss, struct rproc *rproc)
{
	int ret;
	u32 val;
	int temp = 0;
	const struct wcss_data *desc;
	struct device_node *upd_np;
	struct platform_device *upd_pdev;
	struct rproc *upd_rproc;
	struct q6_wcss *upd_wcss;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	/*clear boot trigger*/
	writel(0x0, wcss->tcsr_q6_base);

	if (wcss->is_emulation) {
		ret = enable_devsoc_clocks(wcss);
		if (ret)
			return ret;
	}

	writel(0x0, wcss->ce_ahb_base + CE_AHB_CBCR);

	for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
		if (strstr(upd_np->name, "pd") == NULL)
			continue;
		upd_pdev = of_find_device_by_node(upd_np);
		upd_rproc = platform_get_drvdata(upd_pdev);
		upd_wcss = upd_rproc->priv;

		val = readl(upd_wcss->rmb_base + SSCAON_CONFIG);
		val |= BIT(0);
		writel(val, upd_wcss->rmb_base + SSCAON_CONFIG);
	}

	/* Power debug control */
	writel(0x1, wcss->reg_base + Q6_PWR_DBG_CTRL);

	if (debug_wcss)
		writel(0x20000001, wcss->reg_base + Q6SS_DBG_CFG);

	/* Write bootaddr to EVB so that Q6WCSS will jump there after reset */
	writel(rproc->bootaddr >> 4, wcss->reg_base + Q6SS_RST_EVB);

	/*3. BHS require xo cbcr to be enabled */
	val = readl(wcss->reg_base + Q6SS_XO_CBCR);
	val |= 0x1;
	writel(val, wcss->reg_base + Q6SS_XO_CBCR);

	/*4. Enable core cbcr*/
	val = readl(wcss->reg_base + Q6SS_CORE_CBCR);
	val |= 0x1;
	writel(val, wcss->reg_base + Q6SS_CORE_CBCR);

	/*5. Enable sleep cbcr*/
	val = readl(wcss->reg_base + Q6SS_SLEEP_CBCR);
	val |= 0x1;
	writel(val, wcss->reg_base + Q6SS_SLEEP_CBCR);

	/*6. Boot core start */
	writel(0x1, wcss->reg_base + Q6SS_BOOT_CORE_START);

	writel(0x1, wcss->reg_base + Q6SS_BOOT_CMD);

	/* Enable global timer */
	if (wcss->qtimer_base)
		writel(0x1, wcss->qtimer_base);

	/*7. Pray god and wait for reset to complete*/
	while (temp < 20) {
		val = readl(wcss->reg_base + Q6SS_BOOT_STATUS);
		if (val & 0x01)
			break;
		mdelay(1);
		temp++;
	}

	pr_info("%s: start %s\n", wcss->q6.rproc->name,
			val == 1 ? "successful" : "failed");

	/*clear boot trigger*/
	writel(0x0, wcss->tcsr_q6_base);

	/*Q6 AHB upper & lower address*/
	writel(0x00cdc000, wcss->reg_base + Q6SS_AHB_UPPER);

	writel(0x00ca0000, wcss->reg_base + Q6SS_AHB_LOWER);

	ret = regmap_update_bits(wcss->halt_map,
			wcss->halt_nc + TCSR_GLOBAL_CFG1,
			0x1F, 0x18);
	return 0;
}

static void q6v6_wcss_reset(struct q6_wcss *wcss)
{
	u32 val;
	int ret;
	int temp = 0;
	unsigned int cookie;

	/*Assert Q6 BLK Reset*/
	ret = reset_control_assert(wcss->wcss_q6_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_q6_reset failed\n");
		return;
	}

	/* AON Reset */
	ret = reset_control_deassert(wcss->wcss_aon_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_aon_reset failed\n");
		return;
	}

	/*Enable Q6 AXIS CLOCK RESET*/
	ret = clk_prepare_enable(wcss->axmis_clk);
	if (ret) {
		dev_err(wcss->dev, "wcss clk(s) enable failed");
		return;
	}

	/*Disable Q6 AXIS CLOCK RESET*/
	clk_disable_unprepare(wcss->axmis_clk);

	/*De assert Q6 BLK reset*/
	ret = reset_control_deassert(wcss->wcss_q6_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_q6_reset failed\n");
		return;
	}

	/*Prepare Q6 clocks*/
	ret = ipq5018_clks_prepare_enable(wcss);
	if (ret) {
		dev_err(wcss->dev, "wcss clk(s) enable failed");
		return;
	}

	/*Secure access to WIFI phy register*/
	regmap_update_bits(wcss->halt_map,
			wcss->halt_nc + TCSR_GLOBAL_CFG1,
			TCSR_WCSS_CLK_MASK,
			0x18);

	/*Disable Q6 AXI2 select*/
	regmap_update_bits(wcss->halt_map,
			wcss->halt_nc + TCSR_GLOBAL_CFG0, 0x40, 0xF0);

	/*wcss axib ib status*/
	regmap_update_bits(wcss->halt_map,
			wcss->halt_nc + TCSR_GLOBAL_CFG0, 0x100, 0x100);


	/*Q6 AHB upper & lower address*/
	writel(0x00cdc000, wcss->reg_base + Q6SS_AHB_UPPER);
	writel(0x00ca0000, wcss->reg_base + Q6SS_AHB_LOWER);

	/*Configure MSIP*/
	if (wcss->tcsr_msip_base)
		writel(0x1, wcss->tcsr_msip_base + 0x00);

	if (debug_wcss)
		writel(0x20000001, wcss->reg_base + Q6SS_DBG_CFG);
	else
		writel(0x0, wcss->reg_base + Q6SS_DBG_CFG);

	cookie = 1;
	ret = qti_scm_wcss_boot(Q6_BOOT_TRIG_SVC_ID,
				 Q6_BOOT_TRIG_CMD_ID, &cookie);
	if (ret) {
		dev_err(wcss->dev, "q6-boot trigger scm failed\n");
		return;
	}

	/* Boot core start */
	writel(0x1, wcss->reg_base + Q6SS_BOOT_CORE_START);

	while (temp < 20) {
		val = readl(wcss->reg_base + Q6SS_BOOT_STATUS);
		if (val & 0x01)
			break;
		mdelay(1);
		temp += 1;
	}

	pr_err("%s: start %s\n", wcss->q6.rproc->name,
					val == 1 ? "successful" : "failed");
	wcss->q6.running = val == 1 ? true : false;
}

static int q6_wcss_reset(struct q6_wcss *wcss)
{
	int ret;
	u32 val;
	int i;

	/* Assert resets, stop core */
	val = readl(wcss->reg_base + Q6SS_RESET_REG);
	val |= Q6SS_CORE_ARES | Q6SS_BUS_ARES_ENABLE | Q6SS_STOP_CORE;
	writel(val, wcss->reg_base + Q6SS_RESET_REG);

	/* BHS require xo cbcr to be enabled */
	val = readl(wcss->reg_base + Q6SS_XO_CBCR);
	val |= 0x1;
	writel(val, wcss->reg_base + Q6SS_XO_CBCR);

	/* Read CLKOFF bit to go low indicating CLK is enabled */
	ret = readl_poll_timeout(wcss->reg_base + Q6SS_XO_CBCR,
				 val, !(val & BIT(31)), 1,
				 HALT_CHECK_MAX_LOOPS);
	if (ret) {
		dev_err(wcss->dev,
			"xo cbcr enabling timed out (rc:%d)\n", ret);
		return ret;
	}
	/* Enable power block headswitch and wait for it to stabilize */
	val = readl(wcss->reg_base + Q6SS_PWR_CTL_REG);
	val |= Q6SS_BHS_ON;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);
	udelay(1);

	/* Put LDO in bypass mode */
	val |= Q6SS_LDO_BYP;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* Deassert Q6 compiler memory clamp */
	val = readl(wcss->reg_base + Q6SS_PWR_CTL_REG);
	val &= ~Q6SS_CLAMP_QMC_MEM;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* Deassert memory peripheral sleep and L2 memory standby */
	val |= Q6SS_L2DATA_STBY_N | Q6SS_SLP_RET_N;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* Turn on L1, L2, ETB and JU memories 1 at a time */
	val = readl(wcss->reg_base + Q6SS_MEM_PWR_CTL);
	for (i = MEM_BANKS; i >= 0; i--) {
		val |= BIT(i);
		writel(val, wcss->reg_base + Q6SS_MEM_PWR_CTL);
		/*
		 * Read back value to ensure the write is done then
		 * wait for 1us for both memory peripheral and data
		 * array to turn on.
		 */
		val |= readl(wcss->reg_base + Q6SS_MEM_PWR_CTL);
		udelay(1);
	}
	/* Remove word line clamp */
	val = readl(wcss->reg_base + Q6SS_PWR_CTL_REG);
	val &= ~Q6SS_CLAMP_WL;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* Remove IO clamp */
	val &= ~Q6SS_CLAMP_IO;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* Bring core out of reset */
	val = readl(wcss->reg_base + Q6SS_RESET_REG);
	val &= ~Q6SS_CORE_ARES;
	writel(val, wcss->reg_base + Q6SS_RESET_REG);

	/* Turn on core clock */
	val = readl(wcss->reg_base + Q6SS_GFMUX_CTL_REG);
	val |= Q6SS_CLK_ENABLE;
	writel(val, wcss->reg_base + Q6SS_GFMUX_CTL_REG);

	/* Start core execution */
	val = readl(wcss->reg_base + Q6SS_RESET_REG);
	val &= ~Q6SS_STOP_CORE;
	writel(val, wcss->reg_base + Q6SS_RESET_REG);

	return 0;
}

static int handle_upd_in_rpd_crash(void *data)
{
	struct rproc *rpd_rproc = data, *upd_rproc;
	struct q6_wcss *rpd_wcss = rpd_rproc->priv;
	struct device_node *upd_np;
	struct platform_device *upd_pdev;
	const struct firmware *firmware_p;
	int ret;

	while (1) {
		if (rpd_rproc->state == RPROC_RUNNING)
			break;
		udelay(1);
	}

	for_each_available_child_of_node(rpd_wcss->dev->of_node, upd_np) {
		if (strstr(upd_np->name, "pd") == NULL)
			continue;
		upd_pdev = of_find_device_by_node(upd_np);
		upd_rproc = platform_get_drvdata(upd_pdev);

		if (upd_rproc->state != RPROC_SUSPENDED)
			continue;

		/* load firmware */
		ret = request_firmware(&firmware_p, upd_rproc->firmware,
				&upd_pdev->dev);
		if (ret < 0) {
			dev_err(&upd_pdev->dev,
					"request_firmware failed: %d\n", ret);
			continue;
		}

		/* start the userpd rproc*/
		ret = rproc_start(upd_rproc, firmware_p);
		if (ret)
			dev_err(&upd_pdev->dev, "failed to start %s\n",
					upd_rproc->name);
		release_firmware(firmware_p);
	}
	rpd_wcss->state = WCSS_NORMAL;
	return 0;
}

static int q6_wcss_start(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv;
	int ret;
	struct device_node *upd_np;
	struct platform_device *upd_pdev;
	struct rproc *upd_rproc;
	struct q6_wcss *upd_wcss;
	const struct wcss_data *desc;
	int loop = 0;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	qcom_q6v5_prepare(&wcss->q6);

	if (wcss->need_mem_protection) {
		ret = qcom_scm_pas_auth_and_reset(MPD_WCNSS_PAS_ID, debug_wcss,
					wcss->reset_cmd_id);
		if (ret) {
			dev_err(wcss->dev, "wcss_reset failed\n");
			return ret;
		}
		goto wait_for_reset;
	}

	/* Release Q6 and WCSS reset */
	ret = reset_control_deassert(wcss->wcss_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_reset failed\n");
		return ret;
	}

	ret = reset_control_deassert(wcss->wcss_q6_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_q6_reset failed\n");
		goto wcss_reset;
	}

	/* Lithium configuration - clock gating and bus arbitration */
	ret = regmap_update_bits(wcss->halt_map,
				 wcss->halt_nc + TCSR_GLOBAL_CFG0,
				 TCSR_WCSS_CLK_MASK,
				 TCSR_WCSS_CLK_ENABLE);
	if (ret)
		goto wcss_q6_reset;

	if (desc == &q6_devsoc_res_init) {
		while (loop < 100) {
			mdelay(1);
			loop++;
		}
	}

	ret = regmap_update_bits(wcss->halt_map,
				 wcss->halt_nc + TCSR_GLOBAL_CFG1,
				 1, 0);
	if (ret)
		goto wcss_q6_reset;

	if (desc->q6ver == Q6V7)
		q6v7_wcss_reset(wcss, rproc);
	else if (desc->q6ver == Q6V6) {
		/* Write bootaddr to EVB so that Q6WCSS will jump there
		 * after reset
		 */
		writel(rproc->bootaddr >> 4, wcss->reg_base + Q6SS_RST_EVB);
		q6v6_wcss_reset(wcss);
	} else if (desc->q6ver == Q6V5) {
		if (debug_wcss)
			writel(0x20000001, wcss->reg_base + Q6SS_DBG_CFG);
		ret = q6_wcss_reset(wcss);
	}

	if (ret)
		goto wcss_q6_reset;

wait_for_reset:
	ret = qcom_q6v5_wait_for_start(&wcss->q6, 5 * HZ);
	if (ret == -ETIMEDOUT) {
		if (debug_wcss)
			goto wait_for_reset;
		else
			dev_err(wcss->dev, "start timed out\n");
	}

	/*reset done clear the debug register*/
	if (debug_wcss && desc->q6ver != Q6V6)
		writel(0x0, wcss->reg_base + Q6SS_DBG_CFG);

	/* start userpd's, if root pd getting recovered*/
	if (wcss->state == WCSS_RESTARTING) {
		char thread_name[32];

		snprintf(thread_name, sizeof(thread_name), "rootpd_crash");
		kthread_run(handle_upd_in_rpd_crash, rproc, thread_name);
	} else {
		/* Bring userpd wcss state to default value */
		for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
			if (strstr(upd_np->name, "pd") == NULL)
				continue;
			upd_pdev = of_find_device_by_node(upd_np);
			upd_rproc = platform_get_drvdata(upd_pdev);
			upd_wcss = upd_rproc->priv;
			upd_wcss->state = WCSS_NORMAL;
		}
	}
	return ret;

wcss_q6_reset:
	reset_control_assert(wcss->wcss_q6_reset);

wcss_reset:
	reset_control_assert(wcss->wcss_reset);
	if (debug_wcss)
		writel(0x0, wcss->reg_base + Q6SS_DBG_CFG);

	return ret;
}

static int q6_wcss_spawn_pd(struct rproc *rproc)
{
	int ret;
	struct q6_wcss *wcss = rproc->priv;

	ret = qcom_q6v5_request_spawn(&wcss->q6);
	if (ret == -ETIMEDOUT) {
		pr_err("%s spawn timedout\n", rproc->name);
		return ret;
	}

	ret = qcom_q6v5_wait_for_start(&wcss->q6, 5 * HZ);
	if (ret == -ETIMEDOUT) {
		pr_err("%s start timedout\n", rproc->name);
		wcss->q6.running = false;
		return ret;
	}
	wcss->q6.running = true;
	return ret;
}

static int wcss_ahb_pd_start(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv;
	int ret;
	u32 val;
	const struct wcss_data *desc;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);
	struct q6_wcss *rpd_wcss = rpd_rproc->priv;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	if (!desc->reset_seq)
		goto spawn_pd;

	if (wcss->need_mem_protection) {
		ret = qti_scm_int_radio_powerup(MPD_WCNSS_PAS_ID);
		if (ret) {
			dev_err(wcss->dev, "failed to power up ahb pd\n");
			return ret;
		}
		goto spawn_pd;
	}

	/* AON Reset */
	ret = reset_control_deassert(wcss->wcss_aon_reset);
	if (ret) {
		dev_err(wcss->dev, "wcss_aon_reset failed\n");
		return ret;
	}

	if (desc->q6ver == Q6V7) {
		ret = enable_devsoc_wcss_clocks(wcss);
		if (ret) {
			pr_info("Failed to enable devsoc wcss clocks\n");
			return ret;
		}

		/* msip */
		writel(0x1, rpd_wcss->tcsr_msip_base);

		/* wait for msip status */
		ret = readl_poll_timeout(rpd_wcss->tcsr_msip_base + 0x4,
				val, (val & 0x1) == 0x1, 1,
				MSIP_TIMEOUT_US * 10000);
		if (ret) {
			dev_err(wcss->dev,
					"can't get MSIP STATUS rc:%d val:0x%X)\n", ret, val);
			return ret;
		}
	} else {
		/*Enable AHB_S clock*/
		ret = clk_prepare_enable(wcss->gcc_abhs_cbcr);
		if (ret) {
			dev_err(wcss->dev,
					"failed to enable wcss ahb_s clock\n");
			return ret;
		}

		/*Enable ACMT clock*/
		ret = clk_prepare_enable(wcss->acmt_clk);
		if (ret) {
			dev_err(wcss->dev,
					"failed to enable wcss acmt clock\n");
			return ret;
		}

		/*Enable AXI_M clock*/
		ret = clk_prepare_enable(wcss->gcc_axim_cbcr);
		if (ret) {
			dev_err(wcss->dev,
					"failed to enable wcss axi_m clock\n");
			return ret;
		}

		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val &= ~SSCAON_MASK;
		val |= SSCAON_BUS_EN;
		writel(val, wcss->rmb_base + SSCAON_CONFIG);

		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val &= ~(1<<1);
		writel(val, wcss->rmb_base + SSCAON_CONFIG);
		mdelay(2);


		/* 5 - wait for SSCAON_STATUS */
		ret = readl_poll_timeout(wcss->rmb_base + SSCAON_STATUS,
				val, (val & 0xffff) == 0x10, 1000,
				Q6SS_TIMEOUT_US * 10);
		if (ret) {
			dev_err(wcss->dev,
					"can't get SSCAON_STATUS rc:%d)\n", ret);
			return ret;
		}
	}

	if (desc->ce_reset_required) {
		/*Deassert ce reset*/
		ret = reset_control_deassert(wcss->ce_reset);
		if (ret) {
			dev_err(wcss->dev, "ce_reset failed\n");
			return ret;
		}
	}

spawn_pd:
	if (wcss->q6.spawn_bit) {
		ret = q6_wcss_spawn_pd(rproc);
		if (ret)
			return ret;
	}
	wcss->state = WCSS_NORMAL;

	return ret;
}

static int wcss_pcie_pd_start(struct rproc *rproc)
{
	int ret = q6_wcss_spawn_pd(rproc);

	if (!ret) {
		struct q6_wcss *wcss = rproc->priv;

		wcss->state = WCSS_NORMAL;
	}
	return ret;
}

static void q6v7_wcss_halt_axi_port(struct q6_wcss *wcss,
				    struct regmap *halt_map,
				    u32 offset)
{
	unsigned long timeout;
	unsigned int val;
	int ret;

	/* SET TCSR_WCSS_MST_BDG_RESET_REQ_ADDR to 0 */
	regmap_write(halt_map, offset, 0x0);

	/* Wait for MST BDG ACK */
	timeout = jiffies + usecs_to_jiffies(MST_SLV_BDG_ACK_TIMEOUT_US);
	for (;;) {
		udelay(1);
		ret = regmap_read(halt_map, offset + MST_BDG_RESET_ACK, &val);
		if (ret || !val || time_after(jiffies, timeout))
			break;
	}

	/* SET TCSR_WCSS_SLV_BDG_RESET_REQ_ADDR to 0x0 */
	regmap_write(halt_map, offset + SLV_BDG_RESET_REQ, 0x0);

	/* Wait for SLV BDG ACK */
	timeout = jiffies + usecs_to_jiffies(MST_SLV_BDG_ACK_TIMEOUT_US);
	for (;;) {
		udelay(1);
		ret = regmap_read(halt_map, offset + SLV_BDG_RESET_ACK, &val);
		if (ret || !val || time_after(jiffies, timeout))
			break;
	}

	/* SET TCSR_WCSS_MST_BDG_RESET_REQ_ADDR to 1 */
	regmap_write(halt_map, offset, 0x1);

	/* SET TCSR_WCSS_SLV_BDG_RESET_REQ_ADDR to 1 */
	regmap_write(wcss->halt_map, offset + SLV_BDG_RESET_REQ, 0x1);
}

static void q6v6_wcss_halt_axi_port(struct q6_wcss *wcss,
				    struct regmap *halt_map,
				    u32 offset)
{
	unsigned long timeout;
	unsigned int val;
	int ret;

	/* Assert halt request */
	regmap_write(halt_map, offset + AXI_HALTREQ_REG, 1);

	/* Wait for halt */
	timeout = jiffies + msecs_to_jiffies(HALT_ACK_TIMEOUT_MS);
	for (;;) {
		ret = regmap_read(halt_map, offset + AXI_HALTACK_REG, &val);
		if (ret || val || time_after(jiffies, timeout))
			break;

		msleep(1);
	}

	if (offset == wcss->halt_q6) {
		ret = regmap_read(halt_map, offset + AXI_IDLE_REG, &val);
		if (ret || !val)
			dev_err(wcss->dev, "port failed halt\n");
	}

	/* Clear halt request (port will remain halted until reset) */
	regmap_write(halt_map, offset + AXI_HALTREQ_REG, 0);
}

static void q6_wcss_halt_axi_port(struct q6_wcss *wcss,
				    struct regmap *halt_map,
				    u32 offset)
{
	unsigned long timeout;
	unsigned int val;
	int ret;

	/* Check if we're already idle */
	ret = regmap_read(halt_map, offset + AXI_IDLE_REG, &val);
	if (!ret && val)
		return;

	/* Assert halt request */
	regmap_write(halt_map, offset + AXI_HALTREQ_REG, 1);

	/* Wait for halt */
	timeout = jiffies + msecs_to_jiffies(HALT_ACK_TIMEOUT_MS);
	for (;;) {
		ret = regmap_read(halt_map, offset + AXI_HALTACK_REG, &val);
		if (ret || val || time_after(jiffies, timeout))
			break;

		msleep(1);
	}

	ret = regmap_read(halt_map, offset + AXI_IDLE_REG, &val);
	if (ret || !val)
		dev_err(wcss->dev, "port failed halt\n");

	/* Clear halt request (port will remain halted until reset) */
	regmap_write(halt_map, offset + AXI_HALTREQ_REG, 0);
}

static int q6_wcss_powerdown(struct q6_wcss *wcss)
{
	int ret;
	u32 val;
	const struct wcss_data *desc;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	/* 1 - Assert WCSS/Q6 HALTREQ */
	if (desc->q6ver == Q6V7)
		q6v7_wcss_halt_axi_port(wcss, wcss->halt_map, wcss->halt_wcss);
	else if (desc->q6ver == Q6V6)
		q6v6_wcss_halt_axi_port(wcss, wcss->halt_map, wcss->halt_wcss);
	else if (desc->q6ver == Q6V5)
		q6_wcss_halt_axi_port(wcss, wcss->halt_map, wcss->halt_wcss);

	if (desc->q6ver == Q6V6 || desc->q6ver == Q6V7) {
		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val &= ~SSCAON_MASK;
		val |= SSCAON_BUS_EN;
		writel(val, wcss->rmb_base + SSCAON_CONFIG);
	} else if (desc->q6ver == Q6V5) {
		/* 2 - Enable WCSSAON_CONFIG */
		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val |= SSCAON_ENABLE;
		writel(val, wcss->rmb_base + SSCAON_CONFIG);

		/* 3 - Set SSCAON_CONFIG */
		val |= SSCAON_BUS_EN;
		val &= ~SSCAON_BUS_MUX_MASK;
		writel(val, wcss->rmb_base + SSCAON_CONFIG);
	}

	/* 4 - SSCAON_CONFIG 1 */
	val |= BIT(1);
	writel(val, wcss->rmb_base + SSCAON_CONFIG);

	/* 5 - wait for SSCAON_STATUS */
	ret = readl_poll_timeout(wcss->rmb_base + SSCAON_STATUS,
				val, (val & 0xffff) == 0x400, 1000,
				HALT_CHECK_MAX_LOOPS);
	if (ret) {
		dev_err(wcss->dev,
			"can't get SSCAON_STATUS rc:%d val:0x%X)\n", ret, val);
		return ret;
	}
	mdelay(2);

	/* 6 - De-assert WCSS_AON reset */
	reset_control_assert(wcss->wcss_aon_reset);

	if (desc->q6ver == Q6V6 || desc->q6ver == Q6V7) {
		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val &= ~(1<<1);
		writel(val, wcss->rmb_base + SSCAON_CONFIG);
	} else if (desc->q6ver == Q6V5) {
		/* 7 - Disable WCSSAON_CONFIG 13 */
		val = readl(wcss->rmb_base + SSCAON_CONFIG);
		val &= ~SSCAON_ENABLE;
		writel(val, wcss->rmb_base + SSCAON_CONFIG);
	}

	/* 8 - De-assert WCSS/Q6 HALTREQ */
	reset_control_assert(wcss->wcss_reset);

	return 0;
}

static void q6v6_powerdown(struct q6_wcss *wcss)
{
	int ret;
	unsigned int cookie;

	/*Disable clocks*/
	ipq5018_clks_prepare_disable(wcss);

	cookie = 0;
	ret = qti_scm_wcss_boot(Q6_BOOT_TRIG_SVC_ID,
				 Q6_BOOT_TRIG_CMD_ID, &cookie);
	if (ret) {
		dev_err(wcss->dev, "q6-stop trigger scm failed\n");
		return;
	}
}

static int q6_powerdown(struct q6_wcss *wcss)
{
	int ret;
	u32 val;
	int i;
	int loop;
	const struct wcss_data *desc;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	/* 1 - Halt Q6 bus interface */
	if (desc->q6ver == Q6V6 || desc->q6ver == Q6V7)
		q6v6_wcss_halt_axi_port(wcss, wcss->halt_map, wcss->halt_q6);
	else if (desc->q6ver == Q6V5)
		q6_wcss_halt_axi_port(wcss, wcss->halt_map, wcss->halt_q6);

	if (desc->q6ver != Q6V7) {
		/* 2 - Disable Q6 Core clock */
		val = readl(wcss->reg_base + Q6SS_GFMUX_CTL_REG);
		val &= ~Q6SS_CLK_ENABLE;
		writel(val, wcss->reg_base + Q6SS_GFMUX_CTL_REG);
	}
	if (desc->q6ver == Q6V6) {
		q6v6_powerdown(wcss);
		goto reset;
	} else if (desc->q6ver == Q6V7) {
		while (loop < 2000) {
			mdelay(1);
			loop++;
		}

		reset_control_assert(wcss->wcss_q6_reset);

		if (wcss->is_emulation) {
			/*Disable clocks*/
			disable_devsoc_clocks(wcss);
		}
		return 0;
	}

	/* 3 - Clamp I/O */
	val = readl(wcss->reg_base + Q6SS_PWR_CTL_REG);
	val |= Q6SS_CLAMP_IO;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* 4 - Clamp WL */
	val |= QDSS_BHS_ON;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* 5 - Clear Erase standby */
	val &= ~Q6SS_L2DATA_STBY_N;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* 6 - Clear Sleep RTN */
	val &= ~Q6SS_SLP_RET_N;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* 7 - turn off Q6 memory foot/head switch one bank at a time */
	for (i = 0; i < 20; i++) {
		val = readl(wcss->reg_base + Q6SS_MEM_PWR_CTL);
		val &= ~BIT(i);
		writel(val, wcss->reg_base + Q6SS_MEM_PWR_CTL);
		mdelay(1);
	}

	/* 8 - Assert QMC memory RTN */
	val = readl(wcss->reg_base + Q6SS_PWR_CTL_REG);
	val |= Q6SS_CLAMP_QMC_MEM;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);

	/* 9 - Turn off BHS */
	val &= ~Q6SS_BHS_ON;
	writel(val, wcss->reg_base + Q6SS_PWR_CTL_REG);
	udelay(1);

	/* 10 - Wait till BHS Reset is done */
	ret = readl_poll_timeout(wcss->reg_base + Q6SS_BHS_STATUS,
				 val, !(val & BHS_EN_REST_ACK), 1000,
				 HALT_CHECK_MAX_LOOPS);
	if (ret) {
		dev_err(wcss->dev, "BHS_STATUS not OFF (rc:%d)\n", ret);
		return ret;
	}

reset:
	/* 11 -  Assert WCSS reset */
	reset_control_assert(wcss->wcss_reset);

	/* 12 - Assert Q6 reset */
	reset_control_assert(wcss->wcss_q6_reset);

	return 0;
}

static int q6_wcss_stop(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv;
	int ret;

	/* stop userpd's, if root pd getting crashed*/
	if (rproc->state == RPROC_CRASHED) {
		struct device_node *upd_np;
		struct platform_device *upd_pdev;
		struct rproc *upd_rproc;
		struct q6_wcss *upd_wcss;

		/*
		 * Send fatal notification to userpd(s) if rootpd
		 * crashed, irrespective of userpd status.
		 */
		for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
			if (strstr(upd_np->name, "pd") == NULL)
				continue;
			upd_pdev = of_find_device_by_node(upd_np);
			upd_rproc = platform_get_drvdata(upd_pdev);
			rproc_subsys_notify(upd_rproc,
				SUBSYS_PREPARE_FOR_FATAL_SHUTDOWN, true);
		}

		for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
			if (strstr(upd_np->name, "pd") == NULL)
				continue;
			upd_pdev = of_find_device_by_node(upd_np);
			upd_rproc = platform_get_drvdata(upd_pdev);
			upd_wcss = upd_rproc->priv;

			if (upd_rproc->state == RPROC_OFFLINE)
				continue;

			upd_rproc->state = RPROC_CRASHED;

			/* stop the userpd rproc*/
			ret = rproc_stop(upd_rproc, true);
			if (ret)
				dev_err(&upd_pdev->dev, "failed to stop %s\n",
							upd_rproc->name);
			upd_rproc->state = RPROC_SUSPENDED;
		}
	}

	if (wcss->need_mem_protection) {
		ret = qcom_scm_pas_shutdown(MPD_WCNSS_PAS_ID);
		if (ret) {
			dev_err(wcss->dev, "not able to shutdown\n");
			return ret;
		}
		goto pas_done;
	}

	if (wcss->requires_force_stop) {
		ret = qcom_q6v5_request_stop(&wcss->q6);
		if (ret == -ETIMEDOUT) {
			dev_err(wcss->dev, "timed out on wait\n");
			return ret;
		}
	}

	/* Q6 Power down */
	ret = q6_powerdown(wcss);
	if (ret)
		return ret;

pas_done:
	qcom_q6v5_unprepare(&wcss->q6);

	return 0;
}

static int wcss_pcie_pd_stop(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv;
	int ret = 0;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);

	if (rproc->state != RPROC_CRASHED) {
		ret = qcom_q6v5_request_stop(&wcss->q6);
		if (ret) {
			dev_err(&rproc->dev, "ahb pd not stopped\n");
			return ret;
		}
	}

	/*Shut down rootpd, if userpd not crashed*/
	if (rproc->state != RPROC_CRASHED)
		rproc_shutdown(rpd_rproc);

	wcss->state = WCSS_SHUTDOWN;
	return ret;
}

static int wcss_ahb_pd_stop(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv, *rpd_wcss;
	int ret;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);
	const struct wcss_data *desc;

	rpd_wcss = rpd_rproc->priv;
	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	if (!desc->reset_seq)
		goto shut_dn_rpd;

	if (rproc->state != RPROC_CRASHED && wcss->q6.stop_bit) {
		ret = qcom_q6v5_request_stop(&wcss->q6);
		if (ret) {
			dev_err(&rproc->dev, "ahb pd not stopped\n");
			return ret;
		}
	}

	if (wcss->need_mem_protection) {
		ret = qti_scm_int_radio_powerdown(MPD_WCNSS_PAS_ID);
		if (ret) {
			dev_err(wcss->dev, "failed to power down ahb pd\n");
			return ret;
		}
		goto shut_dn_rpd;
	}

	/* WCSS powerdown */
	ret = q6_wcss_powerdown(wcss);
	if (ret) {
		dev_err(wcss->dev, "failed to power down ahb pd wcss %d\n",
					ret);
		return ret;
	}

	if (desc->ce_reset_required) {
		/*Assert ce reset*/
		reset_control_assert(wcss->ce_reset);
		mdelay(2);
	}

	if (desc->q6ver == Q6V6) {
		/*Disable AHB_S clock*/
		clk_disable_unprepare(wcss->gcc_abhs_cbcr);

		/*Disable ACMT clock*/
		clk_disable_unprepare(wcss->acmt_clk);

		/*Disable AXI_M clock*/
		clk_disable_unprepare(wcss->gcc_axim_cbcr);
	} else if (desc->q6ver == Q6V7) {
		disable_devsoc_wcss_clocks(wcss);
		writel(0x0, rpd_wcss->tcsr_msip_base);
	}

	/* Deassert WCSS reset */
	reset_control_deassert(wcss->wcss_reset);

shut_dn_rpd:
	if (rproc->state != RPROC_CRASHED)
		rproc_shutdown(rpd_rproc);
	wcss->state = WCSS_SHUTDOWN;
	return ret;
}

static void *q6_wcss_da_to_va(struct rproc *rproc, u64 da, int len)
{
	struct q6_wcss *wcss = rproc->priv;
	int offset;

	offset = da - wcss->mem_reloc;
	if (offset < 0 || offset + len > wcss->mem_size)
		return NULL;

	return wcss->mem_region + offset;
}

static int share_bootargs_to_q6(struct device *dev)
{
	int ret;
	u32 smem_id, rd_val;
	const char *key = "qcom,bootargs_smem";
	size_t size;
	u16 cnt, tmp, version;
	void *ptr;
	u8 *bootargs_arr;
	struct device_node *np = dev->of_node;

	ret = of_property_read_u32(np, key, &smem_id);
	if (ret) {
		pr_err("failed to get smem id\n");
		return ret;
	}

	ret = qcom_smem_alloc(REMOTE_PID, smem_id,
					Q6_BOOT_ARGS_SMEM_SIZE);
	if (ret && ret != -EEXIST) {
		pr_err("failed to allocate q6 bootargs smem segment\n");
		return ret;
	}

	ptr = qcom_smem_get(REMOTE_PID, smem_id, &size);
	if (IS_ERR(ptr)) {
		pr_err("Unable to acquire smp2p item(%d) ret:%ld\n",
					smem_id, PTR_ERR(ptr));
		return PTR_ERR(ptr);
	}

	/*Version*/
	version = VERSION;
	memcpy_toio(ptr, &version, sizeof(version));
	ptr += sizeof(version);

	cnt = ret = of_property_count_u32_elems(np, "boot-args");
	if (ret < 0) {
		pr_err("failed to read boot args ret:%d\n", ret);
		return ret;
	}

	/* No of elements */
	memcpy_toio(ptr, &cnt, sizeof(u16));
	ptr += sizeof(u16);

	bootargs_arr = kzalloc(cnt, GFP_KERNEL);
	if (!bootargs_arr) {
		pr_err("failed to allocate memory\n");
		return PTR_ERR(bootargs_arr);
	}

	for (tmp = 0; tmp < cnt; tmp++) {
		ret = of_property_read_u32_index(np, "boot-args", tmp, &rd_val);
		if (ret) {
			pr_err("failed to read boot args\n");
			kfree(bootargs_arr);
			return ret;
		}
		bootargs_arr[tmp] = (u8)rd_val;
	}

	/* Copy bootargs */
	memcpy_toio(ptr, bootargs_arr, cnt);
	ptr += (cnt);

	of_node_put(np);
	kfree(bootargs_arr);
	return ret;
}

static int q6_wcss_load(struct rproc *rproc, const struct firmware *fw)
{
	struct q6_wcss *wcss = rproc->priv;
	const struct firmware *m3_fw;
	int ret;
	struct device *dev = wcss->dev;
	const char *m3_fw_name;
	struct device_node *upd_np;
	struct platform_device *upd_pdev;

	if (wcss->backdoor)
		return 0;

	/* Share boot args to Q6 remote processor */
	ret = share_bootargs_to_q6(wcss->dev);
	if (ret && ret != -EINVAL) {
		dev_err(wcss->dev,
				"boot args sharing with q6 failed %d\n",
				ret);
		return ret;
	}

	/* load m3 firmware of userpd's */
	for_each_available_child_of_node(wcss->dev->of_node, upd_np) {
		if (strstr(upd_np->name, "pd") == NULL)
			continue;
		upd_pdev = of_find_device_by_node(upd_np);

		ret = of_property_read_string(upd_np, "m3_firmware",
				&m3_fw_name);
		if (!ret && m3_fw_name) {
			ret = request_firmware(&m3_fw, m3_fw_name,
					&upd_pdev->dev);
			if (ret)
				continue;

			ret = qcom_mdt_load_no_init(wcss->dev, m3_fw,
					m3_fw_name, 0,
					wcss->mem_region, wcss->mem_phys,
					wcss->mem_size, &wcss->mem_reloc);

			release_firmware(m3_fw);

			if (ret) {
				dev_err(wcss->dev,
					"can't load m3_fw.bXX ret:%d\n", ret);
				return ret;
			}
		}
	}

	ret = of_property_read_string(dev->of_node, "m3_firmware", &m3_fw_name);
	if (!ret && m3_fw_name) {
		ret = request_firmware(&m3_fw, m3_fw_name,
				       wcss->dev);
		if (ret)
			goto skip_m3;

		ret = qcom_mdt_load_no_init(wcss->dev, m3_fw,
					    m3_fw_name, 0,
					    wcss->mem_region, wcss->mem_phys,
					    wcss->mem_size, &wcss->mem_reloc);

		release_firmware(m3_fw);

		if (ret) {
			dev_err(wcss->dev, "can't load m3_fw.bXX ret:%d\n",
									ret);
			return ret;
		}
	}

skip_m3:
	if (wcss->need_mem_protection)
		return qcom_mdt_load(wcss->dev, fw, rproc->firmware,
				     MPD_WCNSS_PAS_ID, wcss->mem_region,
				     wcss->mem_phys, wcss->mem_size,
				     &wcss->mem_reloc);

	return qcom_mdt_load_no_init(wcss->dev, fw, rproc->firmware,
				     0, wcss->mem_region, wcss->mem_phys,
				     wcss->mem_size, &wcss->mem_reloc);
}

static int wcss_ahb_pcie_pd_load(struct rproc *rproc, const struct firmware *fw)
{
	struct q6_wcss *wcss = rproc->priv, *wcss_rpd;
	struct rproc *rpd_rproc = dev_get_drvdata(wcss->dev->parent);
	int ret;

	wcss_rpd = rpd_rproc->priv;

	/* Simply Return in case of
	 * 1) Root pd recovery
	 */
	if (wcss_rpd->state == WCSS_RESTARTING)
		return 0;

	/* Don't boot rootpd rproc incase user pd recovering after crash */
	if (wcss->state != WCSS_RESTARTING) {
		/* Boot rootpd rproc*/
		ret = rproc_boot(rpd_rproc);
		if (ret || wcss->state == WCSS_NORMAL)
			return ret;
	}

	if (wcss->need_mem_protection)
		return qcom_mdt_load(wcss->dev, fw, rproc->firmware,
				     MPD_WCNSS_PAS_ID, wcss->mem_region,
				     wcss->mem_phys, wcss->mem_size,
				     &wcss->mem_reloc);

	return qcom_mdt_load_no_init(wcss->dev, fw, rproc->firmware,
				     0, wcss->mem_region, wcss->mem_phys,
				     wcss->mem_size, &wcss->mem_reloc);
}

int q6_wcss_register_dump_segments(struct rproc *rproc,
					const struct firmware *fw)
{
	/*
	 * Registering custom coredump function with a dummy dump segment
	 * as the dump regions are taken care by the dump function itself
	 */
	return rproc_coredump_add_custom_segment(rproc, 0, 0, crashdump_init,
									NULL);
}

static void q6_wcss_panic(struct rproc *rproc)
{
	struct q6_wcss *wcss = rproc->priv;

	qcom_q6v5_panic_handler(&wcss->q6);
}

static const struct rproc_ops wcss_pcie_ipq5018_ops = {
	.start = wcss_pcie_pd_start,
	.stop = wcss_pcie_pd_stop,
	.load = wcss_ahb_pcie_pd_load,
	.parse_fw = q6_wcss_register_dump_segments,
};

static const struct rproc_ops wcss_ahb_ipq5018_ops = {
	.start = wcss_ahb_pd_start,
	.stop = wcss_ahb_pd_stop,
	.load = wcss_ahb_pcie_pd_load,
	.parse_fw = q6_wcss_register_dump_segments,
};

static const struct rproc_ops q6_wcss_ipq5018_ops = {
	.start = q6_wcss_start,
	.stop = q6_wcss_stop,
	.da_to_va = q6_wcss_da_to_va,
	.load = q6_wcss_load,
	.get_boot_addr = rproc_elf_get_boot_addr,
	.parse_fw = q6_wcss_register_dump_segments,
	.report_panic = q6_wcss_panic,
};

static int q6_wcss_init_reset(struct q6_wcss *wcss,
				const struct wcss_data *desc)
{
	struct device *dev = wcss->dev;

	if (desc->aon_reset_required) {
		wcss->wcss_aon_reset =
			devm_reset_control_get_shared(dev, "wcss_aon_reset");
		if (IS_ERR(wcss->wcss_aon_reset)) {
			dev_err(wcss->dev,
				"fail to acquire wcss_aon_reset, ret:%ld\n",
				PTR_ERR(wcss->wcss_aon_reset));
			return PTR_ERR(wcss->wcss_aon_reset);
		}
	}

	if (desc->wcss_reset_required) {
		wcss->wcss_reset =
			devm_reset_control_get_exclusive(dev, "wcss_reset");
		if (IS_ERR(wcss->wcss_reset)) {
			dev_err(wcss->dev, "unable to acquire wcss_reset\n");
			return PTR_ERR(wcss->wcss_reset);
		}
	}

	if (desc->wcss_q6_reset_required) {
		wcss->wcss_q6_reset =
			devm_reset_control_get_exclusive(dev, "wcss_q6_reset");
		if (IS_ERR(wcss->wcss_q6_reset)) {
			dev_err(wcss->dev, "unable to acquire wcss_q6_reset\n");
			return PTR_ERR(wcss->wcss_q6_reset);
		}
	}

	if (desc->ce_reset_required) {
		wcss->ce_reset = devm_reset_control_get_exclusive(dev,
								"ce_reset");
		if (IS_ERR(wcss->ce_reset)) {
			dev_err(wcss->dev, "unable to acquire ce_reset\n");
			return PTR_ERR(wcss->ce_reset);
		}
	}

	return 0;
}

static int q6_init_mmio(struct q6_wcss *wcss,
				struct platform_device *pdev)
{
	struct resource *res;
	u32 i;
	const struct wcss_data *desc;

	desc = of_device_get_match_data(wcss->dev);
	if (!desc)
		return -EINVAL;

	for (i = 0; i < pdev->num_resources; i++) {
		struct resource *r = &pdev->resource[i];

		if (unlikely(!r->name))
			continue;
	}
	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "qdsp6");
	if (!res) {
		dev_err(&pdev->dev, "qdsp6 resource not available\n");
		return -EINVAL;
	}
	wcss->reg_base = devm_ioremap(&pdev->dev, res->start,
			resource_size(res));
	if (IS_ERR(wcss->reg_base))
		return PTR_ERR(wcss->reg_base);

	if (desc->q6ver == Q6V6 || desc->q6ver == Q6V7) {
		res = platform_get_resource_byname(pdev,
				IORESOURCE_MEM, "tcsr-msip");
		if (res) {
			wcss->tcsr_msip_base =
				devm_ioremap_resource(&pdev->dev, res);
			if (IS_ERR(wcss->tcsr_msip_base))
				return PTR_ERR(wcss->tcsr_msip_base);
		}

		res = platform_get_resource_byname(pdev,
				IORESOURCE_MEM, "tcsr-q6");
		if (res) {
			wcss->tcsr_q6_base = devm_ioremap_resource(&pdev->dev,
						res);
			if (IS_ERR(wcss->tcsr_q6_base))
				return PTR_ERR(wcss->tcsr_q6_base);
		}
	}

	if (desc->q6ver == Q6V7) {
		res = platform_get_resource_byname(pdev,
				IORESOURCE_MEM, "ce_ahb");
		if (res) {
			wcss->ce_ahb_base = devm_ioremap(&pdev->dev,
							res->start,
							resource_size(res));
			if (IS_ERR(wcss->ce_ahb_base))
				return PTR_ERR(wcss->ce_ahb_base);
		}

		res = platform_get_resource_byname(pdev,
				IORESOURCE_MEM, "qtimer");
		if (res) {
			wcss->qtimer_base = devm_ioremap_resource(&pdev->dev,
								res);
			if (IS_ERR(wcss->qtimer_base))
				return PTR_ERR(wcss->qtimer_base);
		}
	}
	return 0;
}

static int q6_wcss_init_mmio(struct q6_wcss *wcss,
			       struct platform_device *pdev)
{
	unsigned int halt_reg[MAX_HALT_REG] = {0};
	struct device_node *syscon;
	struct resource *res;
	int ret;

	if (wcss->version == Q6_IPQ) {
		ret = q6_init_mmio(wcss, pdev);
		if (ret)
			return ret;
	} else if (wcss->version == WCSS_AHB_IPQ) {
		res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "rmb");
		wcss->rmb_base = devm_ioremap_resource(&pdev->dev, res);
		if (IS_ERR(wcss->rmb_base))
			return PTR_ERR(wcss->rmb_base);
	}

	syscon = of_parse_phandle(pdev->dev.of_node,
				  "qcom,halt-regs", 0);
	if (!syscon) {
		dev_err(&pdev->dev, "failed to parse qcom,halt-regs\n");
		return -EINVAL;
	}

	wcss->halt_map = syscon_node_to_regmap(syscon);
	of_node_put(syscon);
	if (IS_ERR(wcss->halt_map))
		return PTR_ERR(wcss->halt_map);

	ret = of_property_read_variable_u32_array(pdev->dev.of_node,
						  "qcom,halt-regs",
						  halt_reg, 0,
						  MAX_HALT_REG);
	if (ret < 0) {
		dev_err(&pdev->dev, "failed to parse qcom,halt-regs\n");
		return -EINVAL;
	}

	wcss->halt_q6 = halt_reg[1];
	wcss->halt_wcss = halt_reg[2];
	wcss->halt_nc = halt_reg[3];
	return 0;
}

static int q6_alloc_memory_region(struct q6_wcss *wcss)
{
	struct reserved_mem *rmem = NULL;
	struct device_node *node;
	struct device *dev = wcss->dev;

	if (wcss->version == Q6_IPQ) {
		node = of_parse_phandle(dev->of_node, "memory-region", 0);
		if (node)
			rmem = of_reserved_mem_lookup(node);

		of_node_put(node);

		if (!rmem) {
			dev_err(dev, "unable to acquire memory-region\n");
			return -EINVAL;
		}
	} else {
		struct rproc *rpd_rproc = dev_get_drvdata(dev->parent);
		struct q6_wcss *rpd_wcss = rpd_rproc->priv;

		wcss->mem_phys = rpd_wcss->mem_phys;
		wcss->mem_reloc = rpd_wcss->mem_reloc;
		wcss->mem_size = rpd_wcss->mem_size;
		wcss->mem_region = rpd_wcss->mem_region;
		return 0;
	}

	wcss->mem_phys = rmem->base;
	wcss->mem_reloc = rmem->base;
	wcss->mem_size = rmem->size;
	wcss->mem_region = devm_ioremap_wc(dev, wcss->mem_phys, wcss->mem_size);
	if (!wcss->mem_region) {
		dev_err(dev, "unable to map memory region: %pa+%pa\n",
			&rmem->base, &rmem->size);
		return -EBUSY;
	}

	return 0;
}

static int ipq5018_init_wcss_clock(struct q6_wcss *wcss)
{
	int ret;

	wcss->gcc_abhs_cbcr = devm_clk_get(wcss->dev, "gcc_wcss_ahb_s_clk");
	if (IS_ERR(wcss->gcc_abhs_cbcr)) {
		ret = PTR_ERR(wcss->gcc_abhs_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get gcc ahbs clock");
		return PTR_ERR(wcss->gcc_abhs_cbcr);
	}

	wcss->acmt_clk = devm_clk_get(wcss->dev, "gcc_wcss_acmt_clk");
	if (IS_ERR(wcss->acmt_clk)) {
		ret = PTR_ERR(wcss->acmt_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get acmt clk\n");
		return PTR_ERR(wcss->acmt_clk);
	}

	wcss->gcc_axim_cbcr = devm_clk_get(wcss->dev, "gcc_wcss_axi_m_clk");
	if (IS_ERR(wcss->gcc_axim_cbcr)) {
		ret = PTR_ERR(wcss->gcc_axim_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get gcc axim clock\n");
		return PTR_ERR(wcss->gcc_axim_cbcr);
	}
	return 0;
}

static int devsoc_init_wcss_clock(struct q6_wcss *wcss)
{
	int ret;

	wcss->dbg_apb_bdg_clk =
			devm_clk_get(wcss->dev, "dbg-apb-bdg");
	if (IS_ERR(wcss->dbg_apb_bdg_clk)) {
		ret = PTR_ERR(wcss->dbg_apb_bdg_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "Failed to get dbg_apb_bdg_clk clock\n");
		return ret;
	}

	wcss->dbg_nts_clk = devm_clk_get(wcss->dev, "dbg-nts");
	if (IS_ERR(wcss->dbg_nts_clk)) {
		ret = PTR_ERR(wcss->dbg_nts_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get dbg nts clock");
		return PTR_ERR(wcss->dbg_nts_clk);
	}

	wcss->axi_s_clk = devm_clk_get(wcss->dev, "wcss_axi_s_clk");
	if (IS_ERR(wcss->axi_s_clk)) {
		ret = PTR_ERR(wcss->axi_s_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get axi_s_clk clk\n");
		return PTR_ERR(wcss->axi_s_clk);
	}

	wcss->dbg_atb_clk = devm_clk_get(wcss->dev, "dbg-atb");
	if (IS_ERR(wcss->dbg_atb_clk)) {
		ret = PTR_ERR(wcss->dbg_atb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get dbg atb clock");
		return PTR_ERR(wcss->dbg_atb_clk);
	}

	wcss->dbg_atb_bdg_clk = devm_clk_get(wcss->dev, "dbg-atb-bdg");
	if (IS_ERR(wcss->dbg_atb_bdg_clk)) {
		ret = PTR_ERR(wcss->dbg_atb_bdg_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get dbg atb bdg clock");
		return PTR_ERR(wcss->dbg_atb_bdg_clk);
	}

	wcss->dbg_apb_clk = devm_clk_get(wcss->dev, "dbg-apb");
	if (IS_ERR(wcss->dbg_apb_clk)) {
		ret = PTR_ERR(wcss->dbg_apb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get dbg apb clock");
		return PTR_ERR(wcss->dbg_apb_clk);
	}


	wcss->gcc_axim_cbcr = devm_clk_get(wcss->dev, "wcss_axi_m_clk");
	if (IS_ERR(wcss->gcc_axim_cbcr)) {
		ret = PTR_ERR(wcss->gcc_axim_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get gcc axim clock\n");
		return PTR_ERR(wcss->gcc_axim_cbcr);
	}

	wcss->dbg_nts_bdg_clk = devm_clk_get(wcss->dev, "dbg-nts-bdg");
	if (IS_ERR(wcss->dbg_nts_bdg_clk)) {
		ret = PTR_ERR(wcss->dbg_nts_bdg_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get dbg nts bdg clock");
		return PTR_ERR(wcss->dbg_nts_bdg_clk);
	}

	wcss->gcc_ce_axi_clk = devm_clk_get(wcss->dev, "ce-axi");
	if (IS_ERR(wcss->gcc_ce_axi_clk)) {
		ret = PTR_ERR(wcss->gcc_ce_axi_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ce axi clock");
		return PTR_ERR(wcss->gcc_ce_axi_clk);
	}

	wcss->gcc_ce_pcnoc_ahb_clk = devm_clk_get(wcss->dev, "ce-pcnoc-ahb");
	if (IS_ERR(wcss->gcc_ce_pcnoc_ahb_clk)) {
		ret = PTR_ERR(wcss->gcc_ce_pcnoc_ahb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ce pcnoc ahb clock");
		return PTR_ERR(wcss->gcc_ce_pcnoc_ahb_clk);
	}

	wcss->gcc_ce_ahb_clk = devm_clk_get(wcss->dev, "ce-ahb");
	if (IS_ERR(wcss->gcc_ce_ahb_clk)) {
		ret = PTR_ERR(wcss->gcc_ce_ahb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ce ahb clock");
		return PTR_ERR(wcss->gcc_ce_ahb_clk);
	}

	return 0;
}

static int devsoc_init_q6_clock(struct q6_wcss *wcss)
{
	int ret;

	wcss->gcc_q6_tsctr_1to2_clk =
			devm_clk_get(wcss->dev, "q6_tsctr_1to2_clk");
	if (IS_ERR(wcss->gcc_q6_tsctr_1to2_clk)) {
		ret = PTR_ERR(wcss->gcc_q6_tsctr_1to2_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "Failed to get q6_tsctr_1to2 clock\n");
		return ret;
	}

	wcss->gcc_q6ss_trig_clk =
			devm_clk_get(wcss->dev, "q6ss_trig_clk");
	if (IS_ERR(wcss->gcc_q6ss_trig_clk)) {
		ret = PTR_ERR(wcss->gcc_q6ss_trig_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "Failed to get q6ss_trig clock\n");
		return ret;
	}

	wcss->axmis_clk = devm_clk_get(wcss->dev, "q6_axis_clk");
	if (IS_ERR(wcss->axmis_clk)) {
		ret = PTR_ERR(wcss->axmis_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get axmis  clk\n");
		return PTR_ERR(wcss->axmis_clk);
	}

	wcss->ahbs_cbcr = devm_clk_get(wcss->dev, "q6_ahb_s");
	if (IS_ERR(wcss->ahbs_cbcr)) {
		ret = PTR_ERR(wcss->ahbs_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ahbs clock\n");
		return PTR_ERR(wcss->ahbs_cbcr);
	}

	wcss->gcc_q6ss_atbm_clk = devm_clk_get(wcss->dev, "q6ss_atbm_clk");
	if (IS_ERR(wcss->gcc_q6ss_atbm_clk)) {
		ret = PTR_ERR(wcss->gcc_q6ss_atbm_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get q6ss atbm clock\n");
		return PTR_ERR(wcss->gcc_q6ss_atbm_clk);
	}

	wcss->qdsp6ss_abhm_cbcr = devm_clk_get(wcss->dev, "q6_ahb");
	if (IS_ERR(wcss->qdsp6ss_abhm_cbcr)) {
		ret = PTR_ERR(wcss->qdsp6ss_abhm_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get q6 ahb clk\n");
		return PTR_ERR(wcss->qdsp6ss_abhm_cbcr);
	}

	wcss->qdsp6ss_axim_cbcr = devm_clk_get(wcss->dev, "q6_axim");
	if (IS_ERR(wcss->qdsp6ss_axim_cbcr)) {
		ret = PTR_ERR(wcss->qdsp6ss_axim_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to axim clk\n");
		return PTR_ERR(wcss->qdsp6ss_axim_cbcr);
	}

	wcss->gcc_q6ss_pclkdbg_clk =
			devm_clk_get(wcss->dev, "q6ss_pclkdbg_clk");
	if (IS_ERR(wcss->gcc_q6ss_pclkdbg_clk)) {
		ret = PTR_ERR(wcss->gcc_q6ss_pclkdbg_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "Failed to get q6ss_pclkdbg clock\n");
		return ret;
	}

	wcss->axi_s_clk = devm_clk_get(wcss->dev, "wcss_axi_s_clk");
	if (IS_ERR(wcss->axi_s_clk)) {
		ret = PTR_ERR(wcss->axi_s_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get axi_s_clk clk\n");
		return PTR_ERR(wcss->axi_s_clk);
	}

	wcss->eachb_clk = devm_clk_get(wcss->dev, "wcss_ecahb");
	if (IS_ERR(wcss->eachb_clk)) {
		ret = PTR_ERR(wcss->eachb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get  wcss ecahb clk\n");
		return PTR_ERR(wcss->eachb_clk);
	}

	wcss->gcc_sys_noc_wcss_ahb_clk =
			devm_clk_get(wcss->dev, "sys_noc_wcss_ahb");
	if (IS_ERR(wcss->gcc_sys_noc_wcss_ahb_clk)) {
		ret = PTR_ERR(wcss->gcc_sys_noc_wcss_ahb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "Failed to get sys_noc_wcss_ahb clock\n");
		return ret;
	}

	return 0;
}

static int ipq5018_init_q6_clock(struct q6_wcss *wcss)
{
	int ret;

	wcss->ahbs_cbcr = devm_clk_get(wcss->dev, "gcc_q6_ahb_s_clk");
	if (IS_ERR(wcss->ahbs_cbcr)) {
		ret = PTR_ERR(wcss->ahbs_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ahbs clock\n");
		return PTR_ERR(wcss->ahbs_cbcr);
	}

	wcss->qdsp6ss_abhm_cbcr = devm_clk_get(wcss->dev, "gcc_q6_ahb_clk");
	if (IS_ERR(wcss->qdsp6ss_abhm_cbcr)) {
		ret = PTR_ERR(wcss->qdsp6ss_abhm_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get csr cbcr clk\n");
		return PTR_ERR(wcss->qdsp6ss_abhm_cbcr);
	}

	wcss->eachb_clk = devm_clk_get(wcss->dev, "gcc_wcss_ecahb_clk");
	if (IS_ERR(wcss->eachb_clk)) {
		ret = PTR_ERR(wcss->eachb_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get ahbs_cbcr clk\n");
		return PTR_ERR(wcss->eachb_clk);
	}


	wcss->gcc_axim2_clk = devm_clk_get(wcss->dev, "gcc_q6_axim2_clk");
	if (IS_ERR(wcss->gcc_axim2_clk)) {
		ret = PTR_ERR(wcss->gcc_axim2_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get gcc_axim2_clk\n");
		return PTR_ERR(wcss->gcc_axim2_clk);
	}

	wcss->axmis_clk = devm_clk_get(wcss->dev, "gcc_q6_axis_clk");
	if (IS_ERR(wcss->axmis_clk)) {
		ret = PTR_ERR(wcss->axmis_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get axmis  clk\n");
		return PTR_ERR(wcss->axmis_clk);
	}

	wcss->axi_s_clk = devm_clk_get(wcss->dev, "gcc_wcss_axi_s_clk");
	if (IS_ERR(wcss->axi_s_clk)) {
		ret = PTR_ERR(wcss->axi_s_clk);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to get axi_s_clk clk\n");
		return PTR_ERR(wcss->axi_s_clk);
	}

	wcss->qdsp6ss_axim_cbcr = devm_clk_get(wcss->dev, "gcc_q6_axim_clk");
	if (IS_ERR(wcss->qdsp6ss_axim_cbcr)) {
		ret = PTR_ERR(wcss->qdsp6ss_axim_cbcr);
		if (ret != -EPROBE_DEFER)
			dev_err(wcss->dev, "failed to axim clk\n");
		return PTR_ERR(wcss->qdsp6ss_axim_cbcr);
	}

	return 0;
}

static int q6_get_inbound_irq(struct qcom_q6v5 *q6,
			struct platform_device *pdev, const char *int_name,
			irqreturn_t (*handler)(int irq, void *data))
{
	int ret, irq;
	char *interrupt, *tmp = (char *)int_name;
	struct q6_wcss *wcss = q6->rproc->priv;

	irq = ret = platform_get_irq_byname(pdev, int_name);
	if (ret < 0) {
		if (ret != -EPROBE_DEFER)
			dev_err(&pdev->dev,
				"failed to retrieve %s IRQ: %d\n",
					int_name, ret);
		return ret;
	}

	if (!strcmp(int_name, "fatal"))
		q6->fatal_irq = irq;
	else if (!strcmp(int_name, "stop-ack")) {
		q6->stop_irq = irq;
		tmp = "stop_ack";
	} else if (!strcmp(int_name, "ready"))
		q6->ready_irq = irq;
	else if (!strcmp(int_name, "handover"))
		q6->handover_irq  = irq;
	else if (!strcmp(int_name, "spawn-ack")) {
		q6->spawn_irq = irq;
		tmp = "spawn_ack";
	} else {
		dev_err(&pdev->dev, "unknown interrupt\n");
		return -EINVAL;
	}

	interrupt = devm_kzalloc(&pdev->dev, BUF_SIZE, GFP_KERNEL);
	if (!interrupt)
		return -ENOMEM;

	snprintf(interrupt, BUF_SIZE, "q6v5_wcss_userpd%d", wcss->pd_asid);
	strlcat(interrupt, "_", BUF_SIZE);
	strlcat(interrupt, tmp, BUF_SIZE);

	ret = devm_request_threaded_irq(&pdev->dev, irq,
			NULL, handler,
			IRQF_TRIGGER_RISING | IRQF_ONESHOT,
			interrupt, q6);
	if (ret) {
		dev_err(&pdev->dev, "failed to acquire %s irq\n",
				interrupt);
		return ret;
	}
	return 0;
}

static int q6_get_outbound_irq(struct qcom_q6v5 *q6,
			struct platform_device *pdev, const char *int_name)
{
	struct qcom_smem_state *tmp_state;
	unsigned  bit;

	tmp_state = qcom_smem_state_get(&pdev->dev, int_name, &bit);
	if (IS_ERR(tmp_state)) {
		dev_err(&pdev->dev, "failed to acquire %s state\n", int_name);
		return PTR_ERR(tmp_state);
	}

	if (!strcmp(int_name, "stop")) {
		q6->state = tmp_state;
		q6->stop_bit = bit;
	} else if (!strcmp(int_name, "spawn")) {
		q6->spawn_state = tmp_state;
		q6->spawn_bit = bit;
	}

	return 0;
}

static int ipq5018_init_irq(struct qcom_q6v5 *q6,
				struct platform_device *pdev,
				struct rproc *rproc, int remote_id,
				int crash_reason,
				void (*handover)(struct qcom_q6v5 *q6))
{
	int ret;

	q6->rproc = rproc;
	q6->dev = &pdev->dev;
	q6->crash_reason = crash_reason;
	q6->handover = handover;

	init_completion(&q6->start_done);
	init_completion(&q6->stop_done);
	init_completion(&q6->spawn_done);

	ret = q6_get_inbound_irq(q6, pdev, "fatal",
					q6v5_fatal_interrupt);
	if (ret)
		return ret;

	ret = q6_get_inbound_irq(q6, pdev, "ready",
					q6v5_ready_interrupt);
	if (ret)
		return ret;

	ret = q6_get_inbound_irq(q6, pdev, "stop-ack",
					q6v5_stop_interrupt);
	if (ret)
		return ret;

	ret = q6_get_inbound_irq(q6, pdev, "spawn-ack",
					q6v5_spawn_interrupt);
	if (ret)
		return ret;

	ret = q6_get_outbound_irq(q6, pdev, "stop");
	if (ret)
		return ret;

	ret = q6_get_outbound_irq(q6, pdev, "spawn");
	if (ret)
		return ret;

	return 0;
}

static int q6_wcss_probe(struct platform_device *pdev)
{
	const struct wcss_data *desc;
	struct q6_wcss *wcss;
	struct rproc *rproc;
	int ret;
	char *subdev_name;

	desc = of_device_get_match_data(&pdev->dev);
	if (!desc)
		return -EINVAL;

	if (desc->need_mem_protection && !qcom_scm_is_available())
		return -EPROBE_DEFER;

	rproc = rproc_alloc(&pdev->dev, pdev->name, desc->ops,
			    desc->q6_firmware_name, sizeof(*wcss));
	if (!rproc) {
		dev_err(&pdev->dev, "failed to allocate rproc\n");
		return -ENOMEM;
	}
	wcss = rproc->priv;
	wcss->dev = &pdev->dev;
	wcss->version = desc->version;

	wcss->requires_force_stop = desc->requires_force_stop;
	wcss->need_mem_protection = desc->need_mem_protection;
	wcss->reset_cmd_id = desc->reset_cmd_id;

	if (wcss->version != WCSS_PCIE_IPQ) {
		ret = q6_wcss_init_mmio(wcss, pdev);
		if (ret)
			goto free_rproc;
	}

	ret = q6_alloc_memory_region(wcss);
	if (ret)
		goto free_rproc;

	if (desc->init_clock) {
		ret = desc->init_clock(wcss);
		if (ret)
			goto free_rproc;
	}

	ret = q6_wcss_init_reset(wcss, desc);
	if (ret)
		goto free_rproc;

	wcss->is_emulation = of_property_read_bool(pdev->dev.of_node,
						"qcom,emulation");
	if (wcss->is_emulation) {
		ret = of_property_read_u32(pdev->dev.of_node, "bootaddr",
					    &rproc->bootaddr);
		if (ret)
			dev_info(&pdev->dev, "boot addr required for emulation,\
					since it's not there will proceed\
					with PIL images\n");
		else
			wcss->backdoor = true;
	}

	wcss->pd_asid = qcom_get_pd_asid(wcss->dev->of_node);

	if (desc->init_irq) {
		ret = desc->init_irq(&wcss->q6, pdev, rproc, desc->remote_id,
				desc->crash_reason_smem, NULL);
		if (ret)
			goto free_rproc;
	}

	if (desc->glink_subdev_required)
		qcom_add_glink_subdev(rproc, &wcss->glink_subdev);

	subdev_name = (char *)(desc->ssr_name ? desc->ssr_name : pdev->name);
	qcom_add_ssr_subdev(rproc, &wcss->ssr_subdev, subdev_name);

	if (desc->sysmon_name)
		wcss->sysmon = qcom_add_sysmon_subdev(rproc,
						      desc->sysmon_name,
						      desc->ssctl_id);

	rproc->backdoor = wcss->backdoor;
	rproc->auto_boot = desc->need_auto_boot;
	ret = rproc_add(rproc);
	if (ret)
		goto free_rproc;

	platform_set_drvdata(pdev, rproc);

	if (wcss->version == Q6_IPQ) {
		ret = of_platform_populate(wcss->dev->of_node, NULL,
						NULL, wcss->dev);
		if (ret) {
			dev_err(&pdev->dev, "failed to populate wcss pd nodes\n");
			goto free_rproc;
		}
	}
	return 0;

free_rproc:
	rproc_free(rproc);

	return ret;
}

static int q6_wcss_remove(struct platform_device *pdev)
{
	struct rproc *rproc = platform_get_drvdata(pdev);

	rproc_del(rproc);
	rproc_free(rproc);

	return 0;
}

static const struct wcss_data q6_devsoc_res_init = {
	.init_clock = devsoc_init_q6_clock,
	.init_irq = qcom_q6v5_init,
	.q6_firmware_name = "devsoc/q6_fw.mdt",
	.crash_reason_smem = WCSS_CRASH_REASON,
	.remote_id = WCSS_SMEM_HOST,
	.aon_reset_required = true,
	.wcss_q6_reset_required = true,
	.ssr_name = "q6wcss",
	.reset_cmd_id = 0x14,
	.ops = &q6_wcss_ipq5018_ops,
	.need_mem_protection = false,
	.need_auto_boot = false,
	.q6ver = Q6V7,
	.glink_subdev_required = true,
};

static const struct wcss_data q6_ipq5018_res_init = {
	.init_clock = ipq5018_init_q6_clock,
	.init_irq = qcom_q6v5_init,
	.q6_firmware_name = "IPQ5018/q6_fw.mdt",
	.crash_reason_smem = WCSS_CRASH_REASON,
	.aon_reset_required = true,
	.wcss_q6_reset_required = true,
	.ssr_name = "q6wcss",
	.reset_cmd_id = 0x14,
	.ops = &q6_wcss_ipq5018_ops,
	.need_mem_protection = true,
	.need_auto_boot = false,
	.q6ver = Q6V6,
	.glink_subdev_required = true,
};

static const struct wcss_data wcss_ahb_devsoc_res_init = {
	.init_clock = devsoc_init_wcss_clock,
	.q6_firmware_name = "devsoc/q6_fw.mdt",
	.aon_reset_required = true,
	.wcss_reset_required = true,
	.ce_reset_required = true,
	.ops = &wcss_ahb_ipq5018_ops,
	.need_mem_protection = false,
	.need_auto_boot = false,
	.q6ver = Q6V7,
	.version = WCSS_AHB_IPQ,
	.reset_seq = true,
};

static const struct wcss_data wcss_ahb_ipq5018_res_init = {
	.init_clock = ipq5018_init_wcss_clock,
	.init_irq = ipq5018_init_irq,
	.q6_firmware_name = "IPQ5018/q6_fw.mdt",
	.crash_reason_smem = WCSS_CRASH_REASON,
	.aon_reset_required = true,
	.wcss_reset_required = true,
	.ce_reset_required = true,
	.ops = &wcss_ahb_ipq5018_ops,
	.need_mem_protection = true,
	.need_auto_boot = false,
	.q6ver = Q6V6,
	.version = WCSS_AHB_IPQ,
	.reset_seq = true,
};

static const struct wcss_data wcss_pcie_ipq5018_res_init = {
	.init_irq = ipq5018_init_irq,
	.q6_firmware_name = "IPQ5018/q6_fw.mdt",
	.crash_reason_smem = WCSS_CRASH_REASON,
	.ops = &wcss_pcie_ipq5018_ops,
	.need_mem_protection = true,
	.need_auto_boot = false,
	.q6ver = Q6V6,
	.version = WCSS_PCIE_IPQ,
};

static const struct of_device_id q6_wcss_of_match[] = {
	{ .compatible = "qcom,ipq5018-q6-mpd", .data = &q6_ipq5018_res_init },
	{ .compatible = "qcom,devsoc-q6-mpd", .data = &q6_devsoc_res_init },
	{ .compatible = "qcom,ipq5018-wcss-ahb-mpd",
		.data = &wcss_ahb_ipq5018_res_init },
	{ .compatible = "qcom,devsoc-wcss-ahb-mpd",
		.data = &wcss_ahb_devsoc_res_init },
	{ .compatible = "qcom,ipq5018-wcss-pcie-mpd",
		.data = &wcss_pcie_ipq5018_res_init },
	{ },
};
MODULE_DEVICE_TABLE(of, q6_wcss_of_match);

static struct platform_driver q6_wcss_driver = {
	.probe = q6_wcss_probe,
	.remove = q6_wcss_remove,
	.driver = {
		.name = "qcom-q6-mpd",
		.of_match_table = q6_wcss_of_match,
	},
};
module_platform_driver(q6_wcss_driver);
module_param(debug_wcss, int, 0644);

MODULE_DESCRIPTION("Hexagon WCSS Multipd Peripheral Image Loader");
MODULE_LICENSE("GPL v2");
