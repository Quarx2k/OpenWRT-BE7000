// SPDX-License-Identifier: GPL-2.0
/* BE7000 stock2024 QSDK control adapter. No closed-driver ABI extensions. */
#include <linux/module.h>
#include <asm/unaligned.h>
#include "core.h"
#include "qcom-he-compat.h"

static bool be7000_he_compat;
module_param(be7000_he_compat, bool, 0444);
MODULE_PARM_DESC(be7000_he_compat, "Enable tested BE7000 stock2024 HE vendor adapter");

static const struct wiphy_vendor_command *qcom_he_command(struct wiphy *wiphy)
{
	int i;
	for (i = 0; i < wiphy->n_vendor_commands; i++) {
		const struct wiphy_vendor_command *cmd = &wiphy->vendor_commands[i];
		if (cmd->info.vendor_id == 0x1374 && cmd->info.subcmd == 74 &&
		    cmd->doit && cmd->policy == VENDOR_CMD_RAW_DATA)
			return cmd;
	}
	return NULL;
}

bool qcom_he_compat_active(struct cfg80211_registered_device *rdev)
{
	return be7000_he_compat && qcom_he_command(&rdev->wiphy);
}

/* The outer policy validates widths/ranges. Parse again for semantic checks. */
int qcom_he_parse(struct genl_info *info, struct qcom_he_config *cfg)
{
	struct nlattr *tb[7];
	int err;
	memset(cfg, 0, sizeof(*cfg));
	if (info->attrs[NL80211_ATTR_HE_OBSS_PD]) {
		err = nla_parse_nested(tb, 6, info->attrs[NL80211_ATTR_HE_OBSS_PD],
				       NULL, info->extack);
		if (err)
			return err;
		if (!tb[QCOM_HE_SR_CTRL]) {
			NL_SET_ERR_MSG(info->extack, "QSDK HE adapter requires SR_CTRL");
			return -EINVAL;
		}
		cfg->sr = true;
		cfg->ctrl = nla_get_u8(tb[QCOM_HE_SR_CTRL]);
		if (cfg->ctrl & ~0x1f) {
			NL_SET_ERR_MSG(info->extack, "Unsupported SR control bits");
			return -EOPNOTSUPP;
		}
		/* QSDK couples non-SRG enable with presence of the offset field. */
		if (!!(cfg->ctrl & BIT(1)) == !!(cfg->ctrl & BIT(2))) {
			NL_SET_ERR_MSG(info->extack, "QSDK requires non-SRG offset when enabled");
			return -EOPNOTSUPP;
		}
		if (tb[QCOM_HE_MIN]) cfg->min = nla_get_u8(tb[QCOM_HE_MIN]);
		if (tb[QCOM_HE_MAX]) cfg->max = nla_get_u8(tb[QCOM_HE_MAX]);
		if (tb[QCOM_HE_NON_SRG_MAX])
			cfg->non_srg_max = nla_get_u8(tb[QCOM_HE_NON_SRG_MAX]);
		if (cfg->min > cfg->max)
			return -EINVAL;
		if (tb[QCOM_HE_COLOR_BITMAP])
			memcpy(cfg->color_bitmap, nla_data(tb[QCOM_HE_COLOR_BITMAP]), 8);
		if (tb[QCOM_HE_BSSID_BITMAP])
			memcpy(cfg->bssid_bitmap, nla_data(tb[QCOM_HE_BSSID_BITMAP]), 8);
	}
	if (info->attrs[NL80211_ATTR_HE_BSS_COLOR]) {
		err = nla_parse_nested(tb, 3, info->attrs[NL80211_ATTR_HE_BSS_COLOR],
				       NULL, info->extack);
		if (err)
			return err;
		if (tb[3]) {
			NL_SET_ERR_MSG(info->extack, "QSDK partial BSS color mapping is unavailable");
			return -EOPNOTSUPP;
		}
		if (!tb[1])
			return -EINVAL;
		cfg->color = true;
		cfg->bss_color = tb[2] ? 0 : nla_get_u8(tb[1]);
	}
	return 0;
}

static int qcom_he_set(struct cfg80211_registered_device *rdev,
		       struct wireless_dev *wdev, u32 command, u32 field,
		       u32 data, u32 length, u32 flags)
{
	const struct wiphy_vendor_command *cmd = qcom_he_command(&rdev->wiphy);
	struct { struct nlattr attr; u32 value; } args[5];
	u32 values[] = { command, field, data, length, flags };
	int i;
	if (!cmd)
		return -EOPNOTSUPP;
	for (i = 0; i < ARRAY_SIZE(args); i++) {
		args[i].attr.nla_type = 17 + i;
		args[i].attr.nla_len = sizeof(args[i]);
		args[i].value = values[i];
	}
	/* These setters return status, never allocate a vendor reply. RTNL held. */
	return cmd->doit(&rdev->wiphy, wdev, args, sizeof(args));
}

int qcom_he_apply(struct cfg80211_registered_device *rdev,
		  struct wireless_dev *wdev, struct genl_info *info,
		  const struct qcom_he_config *cfg)
{
	struct wireless_dev *tmp, *radio = NULL;
	int err;
	ASSERT_RTNL();
	if (cfg->color) {
		list_for_each_entry(tmp, &rdev->wiphy.wdev_list, list) {
			if (!tmp->netdev)
				continue;
			if (!strncmp(tmp->netdev->name, "wifi", 4) && !tmp->ssid_len) {
				if (radio)
					return -EOPNOTSUPP;
				radio = tmp;
			} else if (tmp != wdev && tmp->beacon_interval) {
				NL_SET_ERR_MSG(info->extack, "QSDK color is radio-wide; another AP is active");
				return -EOPNOTSUPP;
			}
		}
		if (!radio)
			return -ENODEV;
	}
	if (cfg->sr) {
		err = qcom_he_set(rdev, wdev, 293, 1, !(cfg->ctrl & BIT(0)), 0, 0);
		if (err) goto failed;
		err = qcom_he_set(rdev, wdev, 293, 2, !(cfg->ctrl & BIT(1)), cfg->non_srg_max, 0);
		if (err) goto failed;
		err = qcom_he_set(rdev, wdev, 293, 3, !!(cfg->ctrl & BIT(4)), 0, 0);
		if (err) goto failed;
		err = qcom_he_set(rdev, wdev, 293, 4, !!(cfg->ctrl & BIT(3)), cfg->min, cfg->max);
		if (err) goto failed;
		if (cfg->ctrl & BIT(3)) {
			err = qcom_he_set(rdev, wdev, 296, 1,
				get_unaligned_le32(cfg->color_bitmap + 4),
				get_unaligned_le32(cfg->color_bitmap), 0);
			if (err) goto failed;
			err = qcom_he_set(rdev, wdev, 296, 2,
				get_unaligned_le32(cfg->bssid_bitmap + 4),
				get_unaligned_le32(cfg->bssid_bitmap), 0);
			if (err) goto failed;
		}
	}
	if (cfg->color) {
		err = qcom_he_set(rdev, radio, 333, cfg->bss_color, 1, 0, 0);
		if (err) goto failed;
	}
	if (cfg->sr || cfg->color)
		pr_info("cfg80211: BE7000 HE %s sr=%d ctrl=%u color=%d/%u applied\n",
			wdev->netdev->name, cfg->sr, cfg->ctrl, cfg->color, cfg->bss_color);
	return 0;
failed:
	NL_SET_ERR_MSG(info->extack, "QSDK driver rejected HE configuration");
	return err;
}
