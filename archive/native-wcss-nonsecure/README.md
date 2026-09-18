# Retired non-secure IPQ9574 WCSS bring-up

These patches are retained for reference and are not applied by the build.
Native v6 failed on `gcc_q6_ahb_clk`; v7 preserved QSDK's non-secure clock
order and failed on `gcc_q6_axim_clk` instead. The working Xiaomi/QSDK boot
uses secure PAS6 authentication/reset, not the non-secure path whose clock
order was copied. The active DT now uses the separate secure remoteproc
module. Do not register PAS-owned Q6 gates with GCC's unused-clock cleanup.
