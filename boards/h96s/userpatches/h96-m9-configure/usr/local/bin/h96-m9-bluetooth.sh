#!/bin/sh
# h96-m9-bluetooth.sh — H96 MAX M9 (RK3576) on-board UART Bluetooth bring-up.
#
# The AIC8800D80 combo chip's BT part is wired to UART ttyS4. Its firmware is
# loaded by the WiFi driver (aic8800_fdrv, radxa-aic8800 DKMS) during SDIO
# probe — until wlan0 exists the BT core does not answer HCI at all (verified
# on-board 2026-10-24: hciattach TX:4 cmds / RX:0 events, hci0 DOWN, BD=0).
# systemd runs this (see h96-m9-bluetooth.service); we no longer rely on
# /etc/rc.local because Armbian regenerates rc.local during finalize.
#
# hciattach with -n stays in the foreground so systemd (Type=simple) can
# supervise it; without -n it would daemonize and systemd would lose track.
exec /usr/bin/hciattach -n -s 1500000 /dev/ttyS4 any 1500000 flow nosleep
