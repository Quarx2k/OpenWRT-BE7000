# BE7000-OpenWrt

[English](README.md) · **Русский**

OpenWrt **SNAPSHOT r36754+92-c1b3943aa3** для Xiaomi BE7000 на базе **Linux 6.18.54**. Доступны версии для загрузки с USB-накопителя через **kexec** и со встроенной NAND-памяти. Поддерживаются все аппаратные функции устройства; сброс настроек кнопкой Reset сейчас доступен в NAND-версии.

Поддерживается аппаратное ускорение (PPE offload) для **PPPoE и Ethernet**.

![LuCI на BE7000](images/luci-overview.png)

**[Загрузить сборки](https://github.com/Quarx2k/OpenWRT-BE7000/releases)** — установщики для Windows и Linux.

## Обновление

Доступно онлайн-обновление с сервера через **LuCI → Система → Attended Sysupgrade**.

Чтобы сохранить свои скрипты и другие файлы при обновлении, добавьте их пути в `/etc/sysupgrade.conf`.

## Дополнительный репозиторий пакетов

```sh
mkdir -p /etc/apk/keys /etc/apk/repositories.d
wget -O /etc/apk/keys/be7000-packages.pem \
  https://openwrt.quarx2k.dev/packages/keys/be7000-packages.pem
. /etc/openwrt_release
printf 'https://openwrt.quarx2k.dev/packages/%s/qualcommbe/ipq95xx/packages.adb\n' \
  "$DISTRIB_REVISION" > /etc/apk/repositories.d/be7000.list
apk update
```

<details>
<summary>Доступные пакеты</summary>

- **AmneziaWG** ([Slava-Shchipunov](https://github.com/Slava-Shchipunov/awg-openwrt)): `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg`, `luci-i18n-amneziawg-ru`.
- **SSClash** ([zerolabnet](https://github.com/zerolabnet/SSClash)): `luci-app-ssclash`.

</details>

## Сборка из исходников

Используйте Linux или WSL2 с установленными зависимостями OpenWrt. В примере собирается USB-версия; для NAND замените `config.be7000-usb` на `config.be7000-nand`.

```bash
git clone --branch be7000-snapshot --single-branch \
  https://github.com/Quarx2k/OpenWRT-BE7000.git
cd OpenWRT-BE7000

./scripts/feeds update -a
./scripts/feeds install -a
bash package/utils/luci-app-be7000-wifi/prepare-luci.sh .

cp config.be7000-usb .config
make defconfig
make download -j8
make -j"$(nproc)"
```

Готовые образы, sysupgrade и установщики для Windows/Linux находятся в `bin/targets/qualcommbe/ipq95xx/`.

## Поддержать проект

| Валюта | Сеть | Адрес |
| --- | --- | --- |
| <img src="images/bitcoin.svg" width="24" height="24" alt="BTC"> Bitcoin (BTC) | <img src="images/bitcoin.svg" width="18" height="18" alt=""> Bitcoin | `bc1qs7lpzg9f592k224uvh4qr5np2kn5s46wvg063n` |
| <img src="images/ethereum.svg" width="24" height="24" alt="ETH"> Ethereum (ETH) | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
| <img src="images/usdt.svg" width="24" height="24" alt="USDT"> USDT | <img src="images/ethereum.svg" width="18" height="18" alt=""> Ethereum | `0x1Df32aB802A57E62BA0647FbCce90C7D66Fc0e53` |
| <img src="images/ton.svg" width="24" height="24" alt="TON"> Gram (Toncoin) | <img src="images/ton.svg" width="18" height="18" alt=""> TON | `UQAy362dLRWtsS5a4cRdKT8CRFprJn8VwOrGtZDZF36KF2ME` |
