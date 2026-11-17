#!/system/bin/sh
# Wi-Fi settings seed for a /data without rhizo_wifi_enabled_once
[ "$(settings get global rhizo_wifi_enabled_once)" = 1 ] && exit 0
settings put global airplane_mode_radios cell,bluetooth,uwb,wimax \
  && settings put global wifi_networks_available_notification_on 0 \
  && cmd wifi set-wifi-enabled enabled \
  && settings put global rhizo_wifi_enabled_once 1
