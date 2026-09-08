// SPDX-License-Identifier: GPL-2.0
/* BE7000 stock2024 QSDK control adapter. No closed-driver ABI extensions. */
#include <linux/module.h>
#include <linux/if_arp.h>
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

/* QSDK registers raw radio-control netdevs as wireless interfaces. Keep
 * them for direct vendor requests, but do not advertise them as usable VAPs.
 * Match raw AP controls only; Ethernet data and monitor VAPs stay visible.
 */
bool qcom_is_radio_control(struct cfg80211_registered_device *rdev,
			   struct wireless_dev *wdev)
{
	return qcom_he_compat_active(rdev) && wdev->netdev &&
	       wdev->iftype == NL80211_IFTYPE_AP &&
	       wdev->netdev->type == ARPHRD_IEEE80211;
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

/* QSDK stores the firmware's separate RX/TX NSS nibbles for MCS 0-7,
 * 8-9, 10-11 and 12-13. Current nl80211 uses combined RX/TX bytes for
 * MCS 0-9, 10-11 and 12-13 at each bandwidth (as does ath12k).
 */
static void qcom_eht_mcs(u8 *out, u32 rx, u32 tx)
{
	out[0] = min(rx & 0xf, (rx >> 4) & 0xf) |
		 (min(tx & 0xf, (tx >> 4) & 0xf) << 4);
	out[1] = ((rx >> 8) & 0xf) | (((tx >> 8) & 0xf) << 4);
	out[2] = ((rx >> 12) & 0xf) | (((tx >> 12) & 0xf) << 4);
}

int qcom_eht_put_cap(struct sk_buff *msg,
		     const struct ieee80211_sta_eht_cap *cap)
{
	const struct ieee80211_eht_mcs_nss_supp *mcs = &cap->eht_mcs_nss_supp;
	u8 phy[9], mcs_set[9];

	/* QSDK's padded fields and public structures must retain their ABI.
	 * The modern wire format has MAC[2], PHY[9] and MCS[9]. Attribute 7
	 * is now VENDOR_ELEMS; EHT starts at 8 instead of QSDK's 7.
	 */
	memcpy(phy, cap->eht_cap_elem.phy_cap_info, sizeof(phy));
	/* This QSDK ABI has no EHT PPE thresholds to export. */
	phy[5] &= ~BIT(3);
	qcom_eht_mcs(mcs_set, le32_to_cpu(mcs->rx_mcs_80),
		     le32_to_cpu(mcs->tx_mcs_80));
	qcom_eht_mcs(mcs_set + 3, le32_to_cpu(mcs->rx_mcs_160),
		     le32_to_cpu(mcs->tx_mcs_160));
	qcom_eht_mcs(mcs_set + 6, le32_to_cpu(mcs->rx_mcs_320),
		     le32_to_cpu(mcs->tx_mcs_320));
	if (nla_put(msg, 8, 2, cap->eht_cap_elem.mac_cap_info) ||
	    nla_put(msg, 9, sizeof(phy), phy) ||
	    nla_put(msg, 10, sizeof(mcs_set), mcs_set))
		return -ENOBUFS;
	return 0;
}

int qcom_put_ext_features(struct sk_buff *msg, struct wiphy *wiphy)
{
	u8 features[8] = {};

	memcpy(features, wiphy->ext_features, sizeof(wiphy->ext_features));
	/* QSDK bit 40 is FILS crypto offload, modern bit 40 is AQL.
	 * QSDK bit 43 is its private MLO flag, not protected TWT.
	 * Modern MLO requires a separate API that this adapter cannot expose.
	 */
	features[5] &= ~(BIT(0) | BIT(3));
	if (wiphy_ext_feature_isset(wiphy, NL80211_EXT_FEATURE_FILS_CRYPTO_OFFLOAD))
		features[7] |= BIT(3); /* modern FILS_CRYPTO_OFFLOAD = 59 */
	return nla_put(msg, NL80211_ATTR_EXT_FEATURES, sizeof(features), features);
}

int qcom_apply_tx_power(struct cfg80211_registered_device *rdev,
			struct wireless_dev *wdev,
			const struct cfg80211_chan_def *chandef, int dbm)
{
	int err;

	if (!rdev->ops->set_tx_power || !chandef->chan)
		return -EOPNOTSUPP;
	if (dbm >= 0 && chandef->chan->max_power < 0)
		return -EOPNOTSUPP;
	if (dbm >= 0)
		dbm = min(dbm, chandef->chan->max_power);
	/* The legacy automatic branch only restores the 5 GHz limit. Restore
	 * the 2 GHz limit explicitly before it clears the fixed-power flag.
	 */
	if (dbm < 0 && chandef->chan->band == NL80211_BAND_2GHZ) {
		if (chandef->chan->max_power < 1)
			return -EOPNOTSUPP;
		err = rdev->ops->set_tx_power(&rdev->wiphy, wdev,
					    NL80211_TX_POWER_FIXED,
					    chandef->chan->max_power);
		if (err)
			return err;
	}
	/* QSDK normally takes whole dBm; literal zero restores automatic.
	 * Its >255 encoding passes the low byte as half-dBm while keeping
	 * the fixed-power flag. Thus 0x100 represents fixed 0 dBm.
	 */
	err = rdev->ops->set_tx_power(&rdev->wiphy, wdev,
				    NL80211_TX_POWER_FIXED,
				    dbm < 0 ? 0 : dbm ? dbm : 0x100);
	if (!err)
		pr_info("cfg80211: BE7000 power %s %d dBm (-1=auto) applied\n",
			wdev->netdev->name, dbm);
	return err;
}

int qcom_set_tx_power(struct cfg80211_registered_device *rdev,
		      enum nl80211_tx_power_setting type, int mbm)
{
	struct wireless_dev *wdev;
	struct ieee80211_supported_band *band;
	int dbm, max_dbm = 0, b, c, err;

	ASSERT_RTNL();
	switch (type) {
	case NL80211_TX_POWER_AUTOMATIC:
		dbm = -1;
		break;
	case NL80211_TX_POWER_FIXED:
	case NL80211_TX_POWER_LIMITED:
		/* Keep the standard integer-dBm range used by OpenWrt. */
		if (mbm < 0 || mbm % 100)
			return -EOPNOTSUPP;
		dbm = mbm / 100;
		for (b = 0; b < NUM_NL80211_BANDS; b++) {
			band = rdev->wiphy.bands[b];
			if (!band)
				continue;
			for (c = 0; c < band->n_channels; c++)
				if (!(band->channels[c].flags & IEEE80211_CHAN_DISABLED))
					max_dbm = max(max_dbm, band->channels[c].max_power);
		}
		if (dbm > max_dbm)
			return -EINVAL;
		break;
	default:
		return -EINVAL;
	}

	/* OpenWrt sets power on the PHY before creating AP interfaces. Cache
	 * the request and replay it on START_AP. Existing APs update now.
	 * The vendor setter changes the radio's power limit, not per-VAP RF.
	 */
	list_for_each_entry(wdev, &rdev->wiphy.wdev_list, list) {
		if (!wdev->netdev || !wdev->beacon_interval)
			continue;
		err = qcom_apply_tx_power(rdev, wdev, &wdev->chandef, dbm);
		if (err)
			return err;
	}
	rdev->qcom_txpower_dbm = dbm;
	return 0;
}


/* The QSDK AP driver implements GET_STATION but no station dump, and its
 * GET_STATION response omits rates. Its vendor command 214 supplies the
 * associated MACs and current rates. Consume these synchronous replies in
 * cfg80211 so ordinary nl80211 clients do not need a vendor backend.
 */
bool qcom_sta_compat(struct cfg80211_registered_device *rdev,
		     struct wireless_dev *wdev)
{
	return qcom_he_compat_active(rdev) && wdev->netdev &&
	       wdev->netdev->type == ARPHRD_ETHER &&
	       wdev->iftype == NL80211_IFTYPE_AP;
}

void qcom_sta_enable_stats(struct cfg80211_registered_device *rdev)
{
	struct wireless_dev *radio;
	int err;

	ASSERT_RTNL();
	list_for_each_entry(radio, &rdev->wiphy.wdev_list, list) {
		if (!qcom_is_radio_control(rdev, radio))
			continue;
		/* WIFI_PARAMS / OL_SPECIAL_PARAM_ENABLE_OL_STATS. QSDK's own
		 * boot scripts enable this for Lithium radios. Otherwise the
		 * firmware leaves peer counters, SNR and rate statistics stale.
		 */
		err = qcom_he_set(rdev, radio, 200, 0x200d, 1, 0, 0);
		if (err)
			pr_warn("cfg80211: BE7000 %s station statistics: %d\n",
				radio->netdev->name, err);
	}
}

int qcom_sta_reply(struct qcom_sta_query *query, struct nlattr *data)
{
	struct nlattr *attr;
	int rem;

	if (query->error)
		return query->error;
	nla_for_each_nested(attr, data, rem) {
		const u8 *p = nla_data(attr);
		int left = nla_len(attr);

		if (nla_type(attr) != 1) /* QCA_WLAN_VENDOR_ATTR_PARAM_DATA */
			continue;
		while (left) {
			struct qcom_sta_entry *entry;
			u16 len;
			int signal;

			/* Stable ieee80211req_sta_info prefix in the BE7000 ABI:
			 * len:0, noise:4, SNR:35, MAC:45, TX kbps:100,
			 * inactivity seconds:180, association seconds:192,
			 * RX kbps:212, current peer channel width:244.
			 * IEs and newer tail fields follow the fixed record.
			 */
			if (left < 245)
				goto malformed;
			len = get_unaligned_le16(p);
			if (len < 245 || len > left || !is_valid_ether_addr(p + 45))
				goto malformed;
			if (query->count >= 1024) {
				query->error = -E2BIG;
				return query->error;
			}
			entry = kzalloc(sizeof(*entry), GFP_KERNEL);
			if (!entry) {
				query->error = -ENOMEM;
				return query->error;
			}
			ether_addr_copy(entry->mac, p + 45);
			signal = (s32)get_unaligned_le32(p + 4) + p[35];
			entry->signal = clamp(signal, -127, 0);
			entry->tx_kbps = get_unaligned_le32(p + 100);
			entry->rx_kbps = get_unaligned_le32(p + 212);
			entry->inactive = get_unaligned_le16(p + 180) * 1000;
			switch (p[244]) {
			case 1: entry->bw = RATE_INFO_BW_40; break;
			case 2: entry->bw = RATE_INFO_BW_80; break;
			case 3: entry->bw = RATE_INFO_BW_160; break;
			default: entry->bw = RATE_INFO_BW_20; break;
			}
			entry->connected = min_t(u64, get_unaligned_le64(p + 192), U32_MAX);
			list_add_tail(&entry->list, &query->entries);
			query->count++;
			p += len;
			left -= len;
		}
	}
	if (rem)
		goto malformed;
	return 0;
malformed:
	query->error = -EBADMSG;
	return query->error;
}

void qcom_sta_free(struct qcom_sta_query *query)
{
	struct qcom_sta_entry *entry, *next;

	list_for_each_entry_safe(entry, next, &query->entries, list) {
		list_del(&entry->list);
		kfree(entry);
	}
}

int qcom_sta_query(struct cfg80211_registered_device *rdev,
		   struct wireless_dev *wdev, struct qcom_sta_query *query)
{
	const struct wiphy_vendor_command *cmd = qcom_he_command(&rdev->wiphy);
	struct { struct nlattr attr; u32 value; } arg = {
		.attr = { .nla_len = sizeof(arg), .nla_type = 17 },
		.value = 214,
	};
	int err;

	ASSERT_RTNL();
	memset(query, 0, sizeof(*query));
	INIT_LIST_HEAD(&query->entries);
	if (!cmd || !qcom_sta_compat(rdev, wdev))
		return -EOPNOTSUPP;
	if (WARN_ON(rdev->qcom_sta_query))
		return -EBUSY;
	rdev->qcom_sta_query = query;
	err = cmd->doit(&rdev->wiphy, wdev, &arg, sizeof(arg));
	rdev->qcom_sta_query = NULL;
	if (query->error)
		err = query->error;
	if (err > 0)
		err = -EIO;
	if (err)
		qcom_sta_free(query);
	return err;
}

void qcom_sta_info(struct cfg80211_registered_device *rdev,
		   struct wireless_dev *wdev, struct qcom_sta_entry *entry,
		   struct station_info *sinfo)
{
	memset(sinfo, 0, sizeof(*sinfo));
	/* Keep the driver's packet/byte/retry counters and station flags. */
	if (rdev->ops->get_station)
		rdev->ops->get_station(&rdev->wiphy, wdev->netdev, entry->mac, sinfo);
	sinfo->signal = entry->signal;
	sinfo->connected_time = entry->connected;
	sinfo->inactive_time = entry->inactive;
	sinfo->filled |= BIT_ULL(NL80211_STA_INFO_SIGNAL) |
			 BIT_ULL(NL80211_STA_INFO_CONNECTED_TIME) |
			 BIT_ULL(NL80211_STA_INFO_INACTIVE_TIME);
	if (sinfo->filled & BIT_ULL(NL80211_STA_INFO_BSS_PARAM))
		sinfo->bss_param.beacon_interval = wdev->beacon_interval;
	/* This vendor ABI supplies kbps and the current peer channel width,
	 * but no per-packet MCS/GI.
	 * Export only the measured bitrate; never substitute the maximum
	 * negotiated rate or invent modulation details.
	 */
	if (entry->tx_kbps && entry->tx_kbps / 100 <= U16_MAX) {
		memset(&sinfo->txrate, 0, sizeof(sinfo->txrate));
		sinfo->txrate.legacy = entry->tx_kbps / 100;
		sinfo->txrate.bw = entry->bw;
		sinfo->filled |= BIT_ULL(NL80211_STA_INFO_TX_BITRATE);
	}
	if (entry->rx_kbps && entry->rx_kbps / 100 <= U16_MAX) {
		memset(&sinfo->rxrate, 0, sizeof(sinfo->rxrate));
		sinfo->rxrate.legacy = entry->rx_kbps / 100;
		sinfo->rxrate.bw = entry->bw;
		sinfo->filled |= BIT_ULL(NL80211_STA_INFO_RX_BITRATE);
	}
}
