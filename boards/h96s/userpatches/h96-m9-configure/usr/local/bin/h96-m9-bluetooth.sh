#!/bin/sh
# h96-m9-bluetooth.sh — H96 MAX M9 (RK3576) on-board UART Bluetooth bring-up.
#
# The RTL8723DS combo chip is wired to UART ttyS4. We must attach the HCI
# line discipline before bluetoothd can manage the device. systemd runs this
# (see h96-m9-bluetooth.service); we no longer rely on /etc/rc.local because
# Armbian regenerates rc.local during finalize and would clobber it.
#
# hciattach with -n stays in the foreground so systemd (Type=simple) can
# supervise it; without -n it would daemonize and systemd would lose track.
exec /usr/bin/hciattach -n -s 1500000 /dev/ttyS4 any 1500000 flow nosleep
