// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2016-2018 Linaro Ltd.
 * Copyright (C) 2014 Sony Mobile Communications AB
 * Copyright (c) 2012-2018 The Linux Foundation. All rights reserved.
 * Copyright (c) 2024-2025 Qualcomm Innovation Center, Inc. All rights reserved.
 */
#include <linux/clk.h>
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/io.h>
#include <linux/firmware.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/soc/qcom/mdt_loader.h>

#include "qcom_common.h"
#include "qcom_q6v5.h"
#include "qcom_pil_info.h"

#define WCSS_CRASH_REASON		421

#define WCSS_PAS_ID			0x6

#define Q6_WAIT_TIMEOUT			(5 * HZ)

struct wcss_sec {
	struct device *dev;
	struct qcom_rproc_glink glink_subdev;
	struct qcom_rproc_ssr ssr_subdev;
	struct qcom_q6v5 q6;
	phys_addr_t mem_phys;
	phys_addr_t mem_reloc;
	void *mem_region;
	size_t mem_size;
	const struct wcss_data *desc;

	const char *m3_firmware;
};

struct wcss_data {
	u32 pasid;
	const char *ss_name;
};

static int wcss_sec_start(struct rproc *rproc)
{
	struct wcss_sec *wcss = rproc->priv;
	struct device *dev = wcss->dev;
	int ret;

	ret = qcom_q6v5_prepare(&wcss->q6);
	if (ret)
		return ret;

	ret = qcom_scm_pas_auth_and_reset(wcss->desc->pasid);
	if (ret) {
		dev_err(dev, "PAS authentication/reset failed: %d\n", ret);
		goto unprepare;
	}

	ret = qcom_q6v5_wait_for_start(&wcss->q6, Q6_WAIT_TIMEOUT);
	if (ret == -ETIMEDOUT)
		dev_err(dev, "start timed out\n");

unprepare:
	qcom_q6v5_unprepare(&wcss->q6);

	return ret;
}

static int wcss_sec_stop(struct rproc *rproc)
{
	struct wcss_sec *wcss = rproc->priv;
	struct device *dev = wcss->dev;
	int ret;

	ret = qcom_scm_pas_shutdown(wcss->desc->pasid);
	if (ret) {
		dev_err(dev, "not able to shutdown\n");
		return ret;
	}

	qcom_q6v5_unprepare(&wcss->q6);

	return 0;
}

static void *wcss_sec_da_to_va(struct rproc *rproc, u64 da, size_t len,
			       bool *is_iomem)
{
	struct wcss_sec *wcss = rproc->priv;
	u64 offset;

	if (da < wcss->mem_reloc)
		return NULL;
	offset = da - wcss->mem_reloc;
	if (offset > wcss->mem_size || len > wcss->mem_size - offset)
		return NULL;

	if (is_iomem)
		*is_iomem = true;
	return wcss->mem_region + offset;
}

static int wcss_sec_load(struct rproc *rproc, const struct firmware *fw)
{
	struct wcss_sec *wcss = rproc->priv;
	struct device *dev = wcss->dev;
	const struct firmware *m3;
	phys_addr_t m3_reloc;
	int ret;

	ret = qcom_mdt_load(dev, fw, rproc->firmware, wcss->desc->pasid,
			    wcss->mem_region, wcss->mem_phys, wcss->mem_size,
			    &wcss->mem_reloc);
	if (ret)
		return ret;

	ret = request_firmware(&m3, wcss->m3_firmware, dev);
	if (ret)
		return dev_err_probe(dev, ret, "Failed to request M3 firmware\n");

	/* M3 shares the Q6 reservation but must not replace Q6's relocation. */
	ret = qcom_mdt_load_no_init(dev, m3, wcss->m3_firmware,
				  wcss->mem_region, wcss->mem_phys,
				  wcss->mem_size, &m3_reloc);
	release_firmware(m3);
	if (ret)
		return ret;

	qcom_pil_info_store("wcss", wcss->mem_phys, wcss->mem_size);

	return 0;
}

static unsigned long wcss_sec_panic(struct rproc *rproc)
{
	struct wcss_sec *wcss = rproc->priv;

	return qcom_q6v5_panic(&wcss->q6);
}

static void wcss_sec_copy_segment(struct rproc *rproc,
				  struct rproc_dump_segment *segment,
				  void *dest, size_t offset, size_t size)
{
	struct wcss_sec *wcss = rproc->priv;
	struct device *dev = wcss->dev;

	/* Use the existing callback-private field, preserving the kernel ABI. */
	if (!segment->priv)
		segment->priv = ioremap_wc(segment->da, segment->size);

	if (!segment->priv) {
		dev_err(dev, "Failed to ioremap segment %pad size 0x%zx\n",
			&segment->da, segment->size);
		memset(dest, 0xff, size);
		return;
	}

	memcpy_fromio(dest, segment->priv + offset, size);
	if (offset + size >= segment->size) {
		iounmap(segment->priv);
		segment->priv = NULL;
	}
}

static int wcss_sec_dump_segments(struct rproc *rproc,
				  const struct firmware *fw)
{
	struct device *dev = rproc->dev.parent;
	struct reserved_mem *rmem = NULL;
	struct device_node *node;
	int num_segs, index;
	int ret;

	/*
	 * Parse through additional reserved memory regions for the rproc
	 * and add them to the coredump segments
	 */
	num_segs = of_count_phandle_with_args(dev->of_node,
					      "memory-region", NULL);
	for (index = 0; index < num_segs; index++) {
		node = of_parse_phandle(dev->of_node,
					"memory-region", index);
		if (!node)
			return -EINVAL;

		rmem = of_reserved_mem_lookup(node);
		of_node_put(node);
		if (!rmem) {
			dev_err(dev, "unable to acquire memory-region index %d num_segs %d\n",
				index, num_segs);
			return -EINVAL;
		}

		dev_dbg(dev, "Adding segment 0x%pa size 0x%pa",
			&rmem->base, &rmem->size);
		ret = rproc_coredump_add_custom_segment(rproc,
							rmem->base,
							rmem->size,
							wcss_sec_copy_segment,
							NULL);
		if (ret)
			return ret;
	}

	return 0;
}

static const struct rproc_ops wcss_sec_ops = {
	.start = wcss_sec_start,
	.stop = wcss_sec_stop,
	.da_to_va = wcss_sec_da_to_va,
	.load = wcss_sec_load,
	.get_boot_addr = rproc_elf_get_boot_addr,
	.panic = wcss_sec_panic,
	.parse_fw = wcss_sec_dump_segments,
};

static int wcss_sec_alloc_memory_region(struct wcss_sec *wcss)
{
	struct reserved_mem *rmem = NULL;
	struct device_node *node;
	struct device *dev = wcss->dev;

	node = of_parse_phandle(dev->of_node, "memory-region", 0);
	if (!node) {
		dev_err(dev, "can't find phandle memory-region\n");
		return -EINVAL;
	}

	rmem = of_reserved_mem_lookup(node);
	of_node_put(node);

	if (!rmem) {
		dev_err(dev, "unable to acquire memory-region\n");
		return -EINVAL;
	}

	wcss->mem_phys = rmem->base;
	wcss->mem_reloc = rmem->base;
	wcss->mem_size = rmem->size;
	wcss->mem_region = devm_ioremap_wc(dev, wcss->mem_phys, wcss->mem_size);
	if (!wcss->mem_region) {
		dev_err(dev, "unable to map memory region: %pa+%pa\n",
			&rmem->base, &rmem->size);
		return -ENOMEM;
	}

	return 0;
}

static int wcss_sec_probe(struct platform_device *pdev)
{
	struct rproc *rproc;
	struct wcss_sec *wcss;
	struct clk *sleep_clk;
	struct clk *int_clk;
	const char *fw_name = NULL;
	const struct wcss_data *desc = of_device_get_match_data(&pdev->dev);
	int ret;

	ret = of_property_read_string(pdev->dev.of_node, "firmware-name",
				      &fw_name);
	if (ret < 0)
		return ret;

	rproc = devm_rproc_alloc(&pdev->dev, desc->ss_name, &wcss_sec_ops,
				 fw_name, sizeof(*wcss));
	if (!rproc) {
		dev_err(&pdev->dev, "failed to allocate rproc\n");
		return -ENOMEM;
	}

	wcss = rproc->priv;
	wcss->dev = &pdev->dev;
	wcss->desc = desc;
	ret = of_property_read_string_index(pdev->dev.of_node, "firmware-name",
					    1, &wcss->m3_firmware);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "Missing M3 firmware-name\n");

	ret = wcss_sec_alloc_memory_region(wcss);
	if (ret)
		return ret;

	sleep_clk = devm_clk_get_optional_enabled(&pdev->dev, "sleep");
	if (IS_ERR(sleep_clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(sleep_clk),
				     "Failed to get sleep clock\n");

	int_clk = devm_clk_get_optional_enabled(&pdev->dev, "interconnect");
	if (IS_ERR(int_clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(int_clk),
				     "Failed to get interconnect clock\n");

	ret = qcom_q6v5_init(&wcss->q6, pdev, rproc,
			     WCSS_CRASH_REASON, NULL, NULL);
	if (ret)
		return ret;

	qcom_add_glink_subdev(rproc, &wcss->glink_subdev, desc->ss_name);
	qcom_add_ssr_subdev(rproc, &wcss->ssr_subdev, desc->ss_name);

	rproc->auto_boot = false;
	rproc->dump_conf = RPROC_COREDUMP_INLINE;
	rproc_coredump_set_elf_info(rproc, ELFCLASS32, EM_NONE);

	ret = devm_rproc_add(&pdev->dev, rproc);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, rproc);

	return 0;
}

static void wcss_sec_remove(struct platform_device *pdev)
{
	struct rproc *rproc = platform_get_drvdata(pdev);
	struct wcss_sec *wcss = rproc->priv;

	qcom_remove_glink_subdev(rproc, &wcss->glink_subdev);
	qcom_remove_ssr_subdev(rproc, &wcss->ssr_subdev);
	qcom_q6v5_deinit(&wcss->q6);
}

static const struct wcss_data wcss_sec_ipq9574_res_init = {
	.pasid = WCSS_PAS_ID,
	.ss_name = "q6wcss",
};

static const struct of_device_id wcss_sec_of_match[] = {
	{ .compatible = "qcom,ipq9574-wcss-sec-pil", .data = &wcss_sec_ipq9574_res_init },
	{ },
};
MODULE_DEVICE_TABLE(of, wcss_sec_of_match);

static struct platform_driver wcss_sec_driver = {
	.probe = wcss_sec_probe,
	.remove = wcss_sec_remove,
	.driver = {
		.name = "qcom-wcss-secure-pil",
		.of_match_table = wcss_sec_of_match,
	},
};
module_platform_driver(wcss_sec_driver);

MODULE_DESCRIPTION("Hexagon WCSS Secure Peripheral Image Loader");
MODULE_LICENSE("GPL");
