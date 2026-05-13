#!/bin/sh
rfkill block 0 && rfkill unblock 0 && /usr/bin/brcm_patchram_plus --enable_hci --use_baudrate_for_download --scopcm=0,2,0,0,0,0,0,0,0,0 --baudrate 3000000 --patchram /system/etc/firmware/bcm43241.hcd --no2bytes --enable_lpm --tosleep=50000 --bd_addr `cat /mnt/factory/bluetooth/bt_mac.txt` -d /dev/ttyTHS2
