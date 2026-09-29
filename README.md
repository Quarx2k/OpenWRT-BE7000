# BE7000-OpenWrt

**English** · [Русский](README.ru.md)

OpenWrt **SNAPSHOT r36538+77-18304dd747** for Xiaomi BE7000, based on **Linux 6.18.52**. Boots from a USB drive using **kexec**. Wi-Fi uses the native ath11k/ath12k drivers.

Hardware acceleration (PPE offload) is supported for **PPPoE and Ethernet**.

![LuCI on BE7000](images/luci-overview.png)

**[Download releases](https://github.com/Quarx2k/OpenWRT-BE7000/releases)** — Windows and Linux installers.

## Updating

Online updates from the server are available through **LuCI → System → Attended Sysupgrade**.

To preserve your scripts and other files during an update, add their paths to `/etc/sysupgrade.conf`.

## Building from source

Use Linux or WSL2 with the OpenWrt build dependencies installed.

```bash
git clone --branch be7000-snapshot --single-branch \
  https://github.com/Quarx2k/OpenWRT-BE7000.git
cd OpenWRT-BE7000

./scripts/feeds update -a
./scripts/feeds install -a
bash package/utils/luci-app-be7000-wifi/prepare-luci.sh .

cp config.be7000-native .config
make defconfig
make download -j8
make -j"$(nproc)"
```

Images and Windows/Linux installer archives are written to "bin/targets/qualcommbe/ipq95xx/".

## Support the project

| Currency | Network | Address |
| --- | --- | --- |
| <img src="images/bitcoin.svg" width="24" height="24" alt="BTC"> Bitcoin (BTC) | <img src="images/bitcoin.svg" width="18" height="18" alt=""> Bitcoin | `bc1qs7lpzg9f592k224uvh4qr5np2kn5s46wvg063n` |
| <img src="images/ethereum.svg" width="24" height="24" alt="ETH"> Ethereum (ETH) | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/ton.svg" width="24" height="24" alt="TON"> Gram (Toncoin) | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
