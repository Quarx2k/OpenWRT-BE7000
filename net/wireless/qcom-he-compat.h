/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QCOM_HE_COMPAT_H
#define QCOM_HE_COMPAT_H

/* nl80211 wire IDs; keep QSDK's public driver structures unchanged. */
enum qcom_he_obss_attr {
	QCOM_HE_MIN = 1, QCOM_HE_MAX, QCOM_HE_NON_SRG_MAX,
	QCOM_HE_COLOR_BITMAP, QCOM_HE_BSSID_BITMAP, QCOM_HE_SR_CTRL,
};

struct qcom_he_config {
	bool sr, color;
	u8 ctrl, min, max, non_srg_max, bss_color;
	u8 color_bitmap[8], bssid_bitmap[8];
};

bool qcom_he_compat_active(struct cfg80211_registered_device *rdev);
int qcom_he_parse(struct genl_info *info, struct qcom_he_config *cfg);
int qcom_he_apply(struct cfg80211_registered_device *rdev,
		  struct wireless_dev *wdev, struct genl_info *info,
		  const struct qcom_he_config *cfg);
int qcom_eht_put_cap(struct sk_buff *msg,
		     const struct ieee80211_sta_eht_cap *cap);
int qcom_put_ext_features(struct sk_buff *msg, struct wiphy *wiphy);
int qcom_set_tx_power(struct cfg80211_registered_device *rdev,
		      enum nl80211_tx_power_setting type, int mbm);
int qcom_apply_tx_power(struct cfg80211_registered_device *rdev,
			struct wireless_dev *wdev,
			const struct cfg80211_chan_def *chandef, int dbm);
bool qcom_is_radio_control(struct cfg80211_registered_device *rdev,
			   struct wireless_dev *wdev);

struct qcom_sta_entry {
	struct list_head list;
	u8 mac[ETH_ALEN];
	s8 signal;
	u8 bw;
	u32 tx_kbps, rx_kbps, connected, inactive;
};
struct qcom_sta_query {
	struct list_head entries;
	unsigned int count;
	int error;
};
bool qcom_sta_compat(struct cfg80211_registered_device *rdev,
		     struct wireless_dev *wdev);
int qcom_sta_query(struct cfg80211_registered_device *rdev,
		   struct wireless_dev *wdev, struct qcom_sta_query *query);
int qcom_sta_reply(struct qcom_sta_query *query, struct nlattr *data);
void qcom_sta_free(struct qcom_sta_query *query);
void qcom_sta_info(struct cfg80211_registered_device *rdev,
		   struct wireless_dev *wdev, struct qcom_sta_entry *entry,
		   struct station_info *sinfo);
void qcom_sta_enable_stats(struct cfg80211_registered_device *rdev);
#endif
