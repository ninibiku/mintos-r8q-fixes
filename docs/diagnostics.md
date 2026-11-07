# 排障 / Diagnostics

这些是定位问题时实际用过的命令，原样贴出来方便复现。
Raw commands used to pin down each defect, kept verbatim so the findings can be reproduced.

前置：手机已 root，`adb shell su -c` 可执行。
Prerequisite: rooted device, `adb shell su -c` works.

---

## 1. 亮度 / Brightness

### 面板真实能力 — what the panel can actually do

```bash
# 面板驱动暴露的上限
adb shell su -c 'cat /sys/class/backlight/panel0-backlight/max_brightness'

# 实测输出（nits）。对照写不同的 brightness 值即可
adb shell su -c 'cat /sys/devices/virtual/lcd/panel/brt_avg'

# 例：255 -> ~420 nits，486 -> ~800 nits
adb shell su -c 'echo 255 > /sys/class/backlight/panel0-backlight/brightness; sleep 2; cat /sys/devices/virtual/lcd/panel/brt_avg'
adb shell su -c 'echo 486 > /sys/class/backlight/panel0-backlight/brightness; sleep 2; cat /sys/devices/virtual/lcd/panel/brt_avg'
```

### 框架侧状态 — framework-side state

```bash
# 框架认为自己在哪个亮度（float 0..1.9058824，x255 就是 sysfs 值）
adb shell su -c "dumpsys display | grep -m1 mBrightnessState"

# HBM / 亮度曲线 / HDR 映射表配置
adb shell su -c "dumpsys display | grep -E 'mHbmData|mHdrBrightnessData|mBrightnessLevels'"

# 每次亮度决策的完整上下文（含 hbmMode、hbmMax、strat）
adb shell su -c "logcat -d -s DisplayPowerController:* | grep BrightnessEvent | tail -5"
```

关键字段：

| 字段 | 含义 |
| --- | --- |
| `brt=1.9058824` | 框架请求的亮度，`x255` = sysfs 值（1.9058824 → 486） |
| `hbmMax` / `hbmMode` | HBM 上限与模式；`hbm:0` 表示 HBM 从未启用 |
| `strat` | 亮度策略，HDR 时是 `OverrideBrightnessStrategy` |
| `thrmMax` | 热降后的上限 |

### 亮度相关设置 — settings

```bash
adb shell su -c 'settings get system screen_brightness'        # 0..255
adb shell su -c 'settings get system screen_brightness_mode'   # 1=自动 0=手动
adb shell su -c 'settings get system display_outdoor_mode'     # 1=户外模式开
```

### 观察「谁在写」 — watching who writes

```bash
# 15 ms 级采样，把输出压成「值 + 连续次数」就能看出是单调爬升还是来回跳
adb shell su -c 'i=0; while [ $i -lt 400 ]; do cat /sys/class/backlight/panel0-backlight/brightness; i=$((i+1)); done' > brt.trace
sort brt.trace | uniq -c
```

`cat` 每次约 5~6 ms，400 次 ≈ 6 秒。若在 trace 里看到同一秒内出现多个相差很大的值，说明有第二个写入者。

---

## 2. HDR 状态 / HDR state

```bash
# 最后一条事件才是当前状态；这个 dump 是历史记录
adb shell su -c "dumpsys SurfaceFlinger --hdr | grep numHdrLayers | tail -3"
```

输出形如：

```
339646693203: numHdrLayers(1), size(2x608),      flags(0), desiredRatio(49.26)
339654996067: numHdrLayers(0), size(0x0),        flags(0), desiredRatio(0.00)
```

| 观察 | 结论 |
| --- | --- |
| 最后一条 `numHdrLayers(0)` | HDR 已结束 |
| `size(2x608)` / `size(32x608)` | 缩略图 / 进度条，**不是**播放 |
| `size(1080x1926)` 这类 | 真正的全屏 HDR 图层 |
| `desiredRatio(49.26)` | HDR 内容与 SDR 白点的亮度比 |

> 踩坑：只看「全历史里最宽的一条」会让模块以为 HDR 永远在播 —— 视频关了之后历史里那条 `1080x…` 还在。

---

## 3. 卡死重启 / Freezes and reboots

### 确认是 ANR 而不是 kernel panic — confirm it is an ANR, not a panic

```bash
adb shell su -c 'ls -lt /data/system/dropbox | head -20'
adb shell su -c 'cat /data/system/dropbox/system_app_anr@*.txt | tail -40'
```

找 `executing service com.android.se/.SecureElementService`。

```bash
# 内核侧线索（重启后仍可读）
adb shell su -c 'cat /proc/last_kmsg | tail -100'
adb shell su -c 'ls /sys/fs/pstore/'
```

### eSE HAL 是否在跑 — is the eSE HAL running

```bash
adb shell su -c 'getprop ro.boot.hardware.sku'
adb shell su -c 'getprop | grep -i secure_element'
adb shell su -c 'ps -A | grep -i secure_element'
```

### HAL 的启动条件 — what gates the HAL

```bash
adb shell su -c 'grep -rn "hardware.sku" /vendor/etc/init/ | head'
```

移植包里应该是 `on property:ro.boot.hardware.sku=s3fwrn5`。

---

## 4. 模块自身 / The module itself

```bash
adb shell su -c 'ps -A -o PID,ARGS | grep outdoor_hbm'          # 进程在不在
adb shell su -c 'cat /data/local/tmp/outdoor_hbm.log'           # 决策日志
adb shell su -c 'ls -l /data/adb/modules/outdoor_hbm_fix/'      # saved_settings / hdr_cap
adb shell su -c 'magisk -v'                                     # Magisk 版本
```

强制重启模块（不用重启手机）：

```bash
adb shell su -c 'for p in $(ps -A -o PID,ARGS | grep outdoor_hbm_fix/service | grep -v grep | awk "{print \$1}"); do kill $p; done'
adb shell su -c 'setsid nohup sh /data/adb/modules/outdoor_hbm_fix/service.sh >/dev/null 2>&1 </dev/null &'
```

---

## 5. 环境测量参考 / Environment notes

在这台设备上量到的一些常数，用来判断读数是否合理：

| 项 | 值 |
| --- | --- |
| 单次 `cat brightness` | ~5.5 ms |
| `sleep 0.01` 实际耗时 | ~43 ms（toybox 精度） |
| `usleep 10000` 实际耗时 | ~31 ms |
| `dumpsys display` | ~60 ms |
| `dumpsys SurfaceFlinger --hdr` | ~80 ms |
| `debug.tracing.screen_state` | 3=亮 2=DOZE（锁屏也是 2）4=灭 —— 本 ROM 上常为空，不能依赖 |
