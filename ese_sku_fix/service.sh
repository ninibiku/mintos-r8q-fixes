#!/system/bin/sh
# Fallback: make sure the HAL is actually running.
if [ "$(getprop init.svc.vendor.secure_element_hal_service-gto)" != "running" ]; then
  setprop ctl.start vendor.secure_element_hal_service-gto
fi