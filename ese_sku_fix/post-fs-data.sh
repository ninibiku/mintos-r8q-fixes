#!/system/bin/sh
# The port's .rc files gate the secure_element HAL on
#   on property:ro.boot.hardware.sku=s3fwrn5
# but the property is empty on r8q, so the HAL never starts and
# com.android.se blocks forever (ANR -> freeze -> watchdog reboot).
resetprop ro.boot.hardware.sku s3fwrn5