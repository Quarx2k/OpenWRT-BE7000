# BE7000-OpenWrt

[English](README.md) · **Русский**

OpenWrt **SNAPSHOT r36538+77-18304dd747** для Xiaomi BE7000 на базе **Linux 6.18.52**. Загрузка с USB-накопителя через **kexec**. Wi-Fi работает на штатных драйверах ath11k/ath12k.

Поддерживается аппаратное ускорение (PPE offload) для **PPPoE и Ethernet**.

![LuCI на BE7000](images/luci-overview.png)

**[Загрузить сборки](https://github.com/Quarx2k/OpenWRT-BE7000/releases)** — установщики для Windows и Linux.

## Обновление

Для обновления с выбранными пакетами из доступных репозиториев используйте
**LuCI → Система → Attended Sysupgrade**. Сервер
[openwrt.quarx2k.dev](https://openwrt.quarx2k.dev/) уже задан в сборке.

Установщики Windows/Linux также умеют обновлять существующую USB-установку
из стоковой прошивки или работающего OpenWrt. Режим обновления сохраняет настройки,
но устанавливает фиксированный набор пакетов из `firmware.bin`; дополнительно
установленные пакеты не переносятся. Свои файлы, например hotplug-скрипты, добавьте
в `/etc/sysupgrade.conf`, чтобы включить их в резервную копию настроек.

## Сборка из исходников

Используйте Linux или WSL2 с установленными зависимостями для сборки OpenWrt.

```bash
git clone --branch be7000-snapshot --single-branch \
  https://github.com/Quarx2k/OpenWRT-BE7000.git
cd OpenWRT-BE7000

./scripts/feeds update -a
./scripts/feeds install -a

cp config.be7000-native .config
make defconfig
make download -j8
make -j"$(nproc)"
```

Готовые образы и архивы установщиков для Windows/Linux находятся в "bin/targets/qualcommbe/ipq95xx/".

## Поддержать проект

| Валюта | Сеть | Адрес |
| --- | --- | --- |
| <img src="images/bitcoin.svg" width="24" height="24" alt="BTC"> Bitcoin (BTC) | <img src="images/bitcoin.svg" width="18" height="18" alt=""> Bitcoin | `bc1qs7lpzg9f592k224uvh4qr5np2kn5s46wvg063n` |
| <img src="images/ethereum.svg" width="24" height="24" alt="ETH"> Ethereum (ETH) | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/ton.svg" width="24" height="24" alt="TON"> Gram (Toncoin) | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
