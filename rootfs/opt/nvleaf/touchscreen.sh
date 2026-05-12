#!/bin/sh
export LD_LIBRARY_PATH=/system/vendor/lib/hw:/system/vendor/lib:/system/lib
export TOUCH_CONF_DIR=/mnt/factory/touchscreen
export TOUCH_DATA_DIR=/data/misc/touchscreen
/opt/nvleaf/rm-wrapper /dev/null
