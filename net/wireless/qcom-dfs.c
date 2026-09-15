// SPDX-License-Identifier: GPL-2.0
/* Translate QSDK's per-channel DFS reports, keeping CAC/radar detection in
 * the driver. No timer here can manufacture a successful CAC completion.
 */
#include <linux/if_arp.h>
#include <linux/module.h>
#include <linux/notifier.h>
#include <linux/rtnetlink.h>
#include <net/wext.h>
#include "core.h"
#include "nl80211.h"
#include "qcom-he-compat.h"

#ifdef CONFIG_WEXT_CORE
static ushort qcom_dfs_event_base = 44;
module_param_named(be7000_dfs_event_base, qcom_dfs_event_base, ushort, 0444);
MODULE_PARM_DESC(be7000_dfs_event_base, "QSDK DFS event ABI: Xiaomi 44, source P74 40");

struct qcom_dfs_event {
	struct work_struct work;
	struct net_device *dev;
	unsigned long timestamp;
	u16 flag, freq;
};

static bool qcom_dfs_contains(const struct cfg80211_chan_def *def, int freq)
{
	int width, center, segment, f;

	switch (def->width) {
	case NL80211_CHAN_WIDTH_20_NOHT:
	case NL80211_CHAN_WIDTH_20: width = 20; break;
	case NL80211_CHAN_WIDTH_40: width = 40; break;
	case NL80211_CHAN_WIDTH_80:
	case NL80211_CHAN_WIDTH_80P80: width = 80; break;
	case NL80211_CHAN_WIDTH_160: width = 160; break;
	default: return false;
	}

	if (!def->chan)
		return false;
	for (segment = 0; segment < 2; segment++) {
		center = segment ? def->center_freq2 : def->center_freq1;
		if (!center)
			continue;
		for (f = center - width / 2 + 10; f < center + width / 2; f += 20)
			if (freq == f)
				return true;
	}
	return false;
}

static bool qcom_dfs_complete(struct wiphy *wiphy,
			      const struct cfg80211_chan_def *def)
{
	struct ieee80211_supported_band *band = wiphy->bands[def->chan->band];
	int i;

	for (i = 0; i < band->n_channels; i++) {
		struct ieee80211_channel *chan = &band->channels[i];

		if (qcom_dfs_contains(def, chan->center_freq) &&
		    (chan->flags & IEEE80211_CHAN_RADAR) &&
		    chan->dfs_state != NL80211_DFS_AVAILABLE)
			return false;
	}
	return true;
}

static void qcom_dfs_work(struct work_struct *work)
{
	struct qcom_dfs_event *event = container_of(work, struct qcom_dfs_event, work);
	struct cfg80211_registered_device *rdev;
	struct wireless_dev *radio, *wdev;
	struct cfg80211_chan_def subchan;
	struct ieee80211_channel *chan;
	struct wiphy *wiphy;
	int type;

	rtnl_lock();
	/* The held netdev reference does not keep a removed wdev alive. */
	if (event->dev->reg_state != NETREG_REGISTERED)
		goto out;
	radio = event->dev->ieee80211_ptr;
	if (!radio)
		goto out;
	wiphy = radio->wiphy;
	rdev = wiphy_to_rdev(wiphy);
	if (!qcom_dfs_compat_active(rdev))
		goto out;
	/* Verified UMAC ABIs: source P74 starts at40, Xiaomi1.1.38 at44. */
	type = (int)event->flag - qcom_dfs_event_base;
	if (type < 0 || type > 3)
		goto out;
	chan = ieee80211_get_channel(wiphy, event->freq);
	if (!chan)
		goto out;
	cfg80211_chandef_create(&subchan, chan, NL80211_CHAN_HT20);

	/* RADAR_DETECTED and NOL_STARTED both invalidate this20MHz channel.
	 * The core maintains its usual minimum non-occupancy timer.
	 */
	if (type == 0 || type == 3) {
		if (chan->dfs_state != NL80211_DFS_UNAVAILABLE)
			cfg80211_radar_event(wiphy, &subchan, GFP_KERNEL);
		list_for_each_entry(wdev, &wiphy->wdev_list, list) {
			if (wdev->netdev && wdev->cac_started &&
			    qcom_dfs_contains(&wdev->chandef, event->freq))
				cfg80211_cac_event(wdev->netdev, &wdev->chandef,
						   NL80211_RADAR_CAC_ABORTED, GFP_KERNEL);
		}
		goto out;
	}

	list_for_each_entry(wdev, &wiphy->wdev_list, list) {
		if (!wdev->netdev || wdev->netdev->type != ARPHRD_ETHER ||
		    wdev->iftype != NL80211_IFTYPE_AP || !wdev->beacon_interval ||
		    !qcom_dfs_contains(&wdev->chandef, event->freq))
			continue;
		if (type == 1 && !wdev->cac_started) {
			wdev->cac_time_ms = cfg80211_chandef_dfs_cac_time(wiphy, &wdev->chandef);
			if (!wdev->cac_time_ms)
				wdev->cac_time_ms = IEEE80211_DFS_MIN_CAC_TIME_MS;
			wdev->cac_start_time = event->timestamp;
			cfg80211_set_dfs_state(wiphy, &wdev->chandef, NL80211_DFS_USABLE);
			cfg80211_cac_event(wdev->netdev, &wdev->chandef,
					   NL80211_RADAR_CAC_STARTED, GFP_KERNEL);
			pr_info("cfg80211: QSDK DFS %s CAC started (%u ms)\n",
				wdev->netdev->name, wdev->cac_time_ms);
		} else if (type == 2 && wdev->cac_started) {
			if (!time_after_eq(event->timestamp, wdev->cac_start_time +
					   msecs_to_jiffies(wdev->cac_time_ms))) {
				pr_warn_ratelimited("cfg80211: QSDK DFS early CAC completion ignored\n");
				continue;
			}
			cfg80211_set_dfs_state(wiphy, &subchan, NL80211_DFS_AVAILABLE);
			if (!qcom_dfs_complete(wiphy, &wdev->chandef))
				continue;
			cfg80211_cac_event(wdev->netdev, &wdev->chandef,
					   NL80211_RADAR_CAC_FINISHED, GFP_KERNEL);
			pr_info("cfg80211: QSDK DFS %s CAC finished\n", wdev->netdev->name);
		}
	}
out:
	rtnl_unlock();
	dev_put(event->dev);
	kfree(event);
}

static int qcom_dfs_notify(struct notifier_block *nb, unsigned long cmd, void *ptr)
{
	const struct wireless_event_info *info = ptr;
	struct qcom_dfs_event *event;

	if (cmd != IWEVCUSTOM || info->wrqu->data.length != sizeof(u16) ||
	    info->wrqu->data.flags < 40 || info->wrqu->data.flags > 47)
		return NOTIFY_DONE;
	event = kmalloc(sizeof(*event), GFP_ATOMIC);
	if (!event)
		return NOTIFY_DONE;
	event->dev = info->dev;
	event->timestamp = jiffies;
	event->flag = info->wrqu->data.flags;
	memcpy(&event->freq, info->extra, sizeof(event->freq));
	dev_hold(event->dev);
	INIT_WORK(&event->work, qcom_dfs_work);
	queue_work(cfg80211_wq, &event->work);
	return NOTIFY_OK;
}

static struct notifier_block qcom_dfs_notifier = {
	.notifier_call = qcom_dfs_notify,
};

int qcom_dfs_init(void)
{
	if (qcom_dfs_event_base != 40 && qcom_dfs_event_base != 44)
		return -EINVAL;
	return register_wireless_event_notifier(&qcom_dfs_notifier);
}

void qcom_dfs_exit(void)
{
	unregister_wireless_event_notifier(&qcom_dfs_notifier);
	flush_workqueue(cfg80211_wq);
}
#else
int qcom_dfs_init(void) { return 0; }
void qcom_dfs_exit(void) { }
#endif
