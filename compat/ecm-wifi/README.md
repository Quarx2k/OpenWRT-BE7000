The four Qualcomm interface headers are copied unchanged from the public
win_wlan_host.1.0.r18 QCA Wi-Fi tree used by QSDK 12.1.r5. Their ISC license
notices are retained. They describe the MSCS, SCS, mesh latency and SAWF API
used by the source-built ECM Wi-Fi plugin.

exports.json lists only the four corresponding exports provided by the
router's vendor umac/wifi_3_0 modules. CONFIG_MODVERSIONS is disabled. This is
link metadata, not function implementations or a replacement WLAN driver.
