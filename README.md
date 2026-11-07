# mintos-r8q-fixes

MintOS (OneUI 8 / Android 16) 移植 ROM 的三星 Galaxy S20 FE 5G (r8q) 补丁集 —— 两个 Magisk 模块，修复这个移植包里三处硬件层缺陷：**随机卡死重启**、**阳光下亮度上不去 / 户外模式反而变暗**、**HDR 视频被钉在 380 nits 且亮度滑块失灵**。

Two Magisk modules that patch hardware-level defects in the **MintOS** (OneUI 8 / Android 16) port for the **Galaxy S20 FE 5G (r8q)**: random freezes that end in a reboot, brightness that never reaches the panel's real ceiling (and Outdoor mode that makes the screen *darker*), and HDR playback stuck at 380 nits with a dead brightness slider.

**中文** ｜ [English](#english)

---

# 中文

## 这是什么

这不是通用模块，是针对**一个具体移植包的三处具体缺陷**打的补丁。每一个改动都来自实测抓到的日志和 sysfs 数据，不是在猜。

> ⚠️ 请先读完整的 [可能发生的问题](#可能发生的问题)。这里没有一条是"理论风险"，都是这套方案固有的取舍。

## 适用环境

| 项目 | 值 |
| --- | --- |
| 设备 | Samsung Galaxy S20 FE 5G，代号 **r8q**（实测 SM-G7810，港版 CSC=TGY） |
| ROM | **MintOS 1.0.0-Paradigm** — OneUI 8.0 / Android 16 / SDK 36，基座 `S916BXXU8EYI5` |
| Root | Magisk **30.6** 及以上（v31.x 实测可用） |
| 面板节点 | `/sys/class/backlight/panel0-backlight/brightness`，`max_brightness = 486` |

**只在这一个 ROM + 这一个机型上验证过。** 模块里没有机型 / ROM 判空，装到别的地方可能反而制造问题。

## 模块一览

| 模块 | 版本 | 修什么 | 需要重启 |
| --- | --- | --- | --- |
| [`ese_sku_fix`](ese_sku_fix/) | v1.0 | eSE HAL 不启动导致 `com.android.se` 死等 → ANR → 卡死重启 | 是 |
| [`outdoor_hbm_fix`](outdoor_hbm_fix/) | v16.0 | 户外模式变暗 / 阳光偏暗 / HDR 被钉在 380 nits | 是（首次装） |

两个模块互相独立，可以只装其中一个。

---

## ese_sku_fix — 修卡死重启

### 症状

用着用着变卡 → 屏幕完全卡死 → 十几秒后自动重启。`/data/system/dropbox/` 里每 1~3 分钟一条：

```
system_app_anr: executing service com.android.se/.SecureElementService, waited 213579ms
```

### 根因

移植包的 HAL 启动条件写死成：

```
on property:ro.boot.hardware.sku=s3fwrn5
```

但 r8q 上 `ro.boot.hardware.sku` **是空的**，条件永远不成立 → `vendor.secure_element_hal_service-gto` 从不启动 → `ISecureElementService` 注册不上 → `com.android.se` 无限等待 → ANR → 系统看门狗重启。

### 修复

[`post-fs-data.sh`](ese_sku_fix/post-fs-data.sh) 在属性服务就绪前补齐：

```sh
resetprop ro.boot.hardware.sku s3fwrn5
```

[`service.sh`](ese_sku_fix/service.sh) 再兜一次底，确保 HAL 真的在跑：

```sh
if [ "$(getprop init.svc.vendor.secure_element_hal_service-gto)" != "running" ]; then
  setprop ctl.start vendor.secure_element_hal_service-gto
fi
```

### 验证

```bash
adb shell su -c 'getprop ro.boot.hardware.sku'                                # 期望 s3fwrn5
adb shell su -c 'getprop init.svc.vendor.secure_element_hal_service-gto'      # 期望 running
adb shell su -c 'ls -lt /data/system/dropbox | head'                          # system_app_anr 不再增长
```

---

## outdoor_hbm_fix — 修亮度

### 三个症状

1. **阳光下自动亮度偏暗**，但手动把滑块拉满反而正常；
2. **开启「户外模式」屏幕反而变暗**，要拉到 60% 左右才最亮；
3. **HDR 视频偏暗，而且亮度滑块完全没用**。

### 这块屏的硬件事实

`/sys/devices/virtual/lcd/panel/brt_avg` 读的是面板实际输出（nits）：

| sysfs `brightness` | 实际亮度 |
| --- | --- |
| 255（框架侧「100%」） | ~420 nits |
| 486（面板 `max_brightness`） | **~800 nits** |

也就是说：**框架只用到面板 52% 的能力**。框架侧 `mBacklightMaximum = 1.9058824`（对应 486），但亮度设置 `screen_brightness` 的上限是 255，中间那段只能靠 HBM 走 —— 而这个移植包报的是：

```
saveBrightnessInfo: brt:0.3764706 adjBrt:3.6323876 min:0.0 max:1.0 hbm:0
```

`hbm:0` = **HBM 从未启用**，486 这段头寸永远拿不到。

### 三个缺陷各自的原理

**① 户外模式反而变暗**

框架确实按 486（`1.9058824`）请求了：

```
Brightness [1.9058824] reason changing to: 'override(...)'
BrightnessEvent: brt=1.9058824 (100.0%), nits=800.0, ... hbmMax=1.0, hbmMode=off
```

但 `max:1.0 / hbm:0` 把它夹住，三星自己的缩放器再把超出的部分映射一次 → 实际落到 **26**。
日志里能直接看到 `Animating target=486(1.91) → saveBrightnessInfo max:1.0 hbm:0 → 最终 26`。

**② 阳光偏暗**

自动亮度曲线在 3000 lux 附近就封顶（约 380 nits），叠加 `hbm:0`，再强的光也上不去。

**③ HDR 被钉死**

`dumpsys display` 里 HDR 的映射表根本没配：

```
mHdrBrightnessData = HdrBrightnessData { ... sdrToHdrRatioSpline: null,
                                         sdrToHdrSpline: null,
                                         highestHdrSdrRatio: 1.0,
                                         transitionPoint: 1.0 }
```

框架算不出「HDR 内容该提到多亮」，只能给固定值 `mBrightnessState = 0.91930795`（= 234 → **380 nits**）。而且 HDR override 期间滑块被完全无视 —— 实测滑块从 10% 扫到 100%，sysfs 一直是 234：

| 滑块 | sysfs | 实际亮度 | 框架目标 |
| --- | --- | --- | --- |
| 26 (10%) | 234 | 380 nits | 0.91930795 |
| 128 (50%) | 234 | 380 nits | 0.91930795 |
| 255 (100%) | 234 | 380 nits | 0.91930795 |

### 为什么早期版本会闪

第一版直接往 sysfs 写 486，但 `DisplayPowerController` 自己的亮度动画**还在往它的低目标爬**。两个写入者交替改同一个节点 —— 这就是「爬到最亮的过程中忽明忽暗」。日志：

```
17:43:13 engaged (lux=10956, was 5)
17:43:20 corrected 238 times     ← 1.5 秒内被框架覆盖 238 次
```

「到了最亮就没事」是因为框架动画跑完了，不再写。

### v16 的做法

1. **先把框架请出去**：切手动亮度 + 滑块拉满，框架目标变成 255，不再向下动画；
2. 等 sysfs 值稳定（框架动画结束）；
3. **单次无竞争的单调渐变**拉到目标；
4. 保持阶段只纠正「**稳定不动**的错误值」，不追着动画打；
5. engage / release 都做了**防抖 + 迟滞**，强光下 lux 抖动不会反复进出；
6. 释放时**按框架的认知值回写面板** —— 框架认为目标没变时会跳过写，否则面板会卡在 800 nits（或者卡在暗处，HDR 就是这么变暗的）；
7. 每 2 秒**对账**一次，只有「连续稳定且偏差 > 6」才纠正，不影响正常亮度动画；
8. HDR 检测**只看 SurfaceFlinger 最后一条事件**，且要求图层宽度 ≥ 700 px（那个 dump 是历史记录，全量信任会让模块以为 HDR 永远在播）；
9. **让位机制**：用户一动滑块或重新开自动亮度，模块 0.5 秒内收手。

### 实测数据

| 场景 | 结果 |
| --- | --- |
| 开户外模式 | `255 → 278 → 301 → … → 485 → 486`，十一级纯单调上升，零回落 |
| 手电筒晃 lux（5000/900/35000/1200/9000/700/20000/1500） | 稳在 486，不抖 |
| 释放（户外模式关） | `486 → 463 → … → 256 → 255` 平滑下降，设置正确还原 |
| 播 HDR | 380 → **800 nits**，40 秒内零纠正 |
| 播 HDR 时拖滑块 | 立刻 `standing down`，之后不再抢写 |
| 退出 HDR | 自动释放回框架值 |

### 配置

可选文件 `/data/adb/modules/outdoor_hbm_fix/hdr_cap`，写入 `0`~`486`，改完重启生效：

```bash
adb shell su -c 'echo 486 > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # 默认，800 nits
adb shell su -c 'echo 420 > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # 柔和些，约 693 nits
adb shell su -c 'echo 0   > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # 完全关掉 HDR 提亮
adb shell su -c 'rm /data/adb/modules/outdoor_hbm_fix/hdr_cap'           # 恢复默认
```

### 日志

```bash
adb shell su -c 'cat /data/local/tmp/outdoor_hbm.log'
```

超过 64 KB 会自动清空。正常内容：

| 行 | 含义 |
| --- | --- |
| `engage (outdoor)` | 因户外模式接管 |
| `engage (lux=44807)` | 因环境光接管 |
| `engage (hdr)` | 因 HDR 播放接管 |
| `release (...)` | 释放，括号里是释放原因 |
| `corrected (was N)` | 框架写了一次数值，被纠正回来（偶发正常，频繁=有东西在抢） |
| `sync N -> M` | 面板与框架认知偏离，对账修正 |
| `user override (...) - standing down` | 你动了滑块，模块让位 |

---

## 安装

**方式一 · Magisk app**：把 `dist/*.zip` 推到手机，Magisk → 模块 → 从本地安装 → 选 zip → 重启。

**方式二 · 命令行**（已 root）：

```bash
adb push dist/ese_sku_fix-v1.0.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/ese_sku_fix-v1.0.zip'
adb reboot
```

zip 里**没有 `META-INF/`**，只能通过 Magisk app 或 `magisk --install-module` 安装，**不能用第三方 Recovery 直接刷**。

## 卸载

Magisk app 里点「移除」，或者：

```bash
adb shell su -c 'rm -rf /data/adb/modules/outdoor_hbm_fix'
adb reboot
```

两个模块都不写系统分区，卸载后系统里不留任何东西。

---

## 可能发生的问题

### 一、兼容性与误刷

| 可能的问题 | 说明 / 处理 |
| --- | --- |
| **装到别的 ROM / 机型上出问题** | 代码写死了 `panel0-backlight` 路径、`s3fwrn5` 这个 SKU、`vendor.secure_element_hal_service-gto` 这个服务名。换个 ROM 这些都不存在：`outdoor_hbm_fix` 会不停写一个不存在的节点（失败但刷 log），`ese_sku_fix` 可能反而让某个本该不启动的 HAL 启动。**换 ROM 前先卸载。** |
| **ROM 更新后行为异常** | OTA / 重刷 ROM 会覆盖 `/vendor`，`ro.boot.hardware.sku` 等前置条件可能变化。每次更新后请重新跑一遍 [验证](#验证) 里的三条命令。 |
| **和别的改亮度的模块打架** | 任何同样在写 `/sys/class/backlight/panel0-backlight/brightness` 或用 `screen_brightness` 做事情的模块（其它 HBM 模块、护眼 / 色温模块、某些 Good Lock 组件）都会和它对冲，表现为亮度反复跳，或者两个都失效。**只留一个。** |
| **和 LSPosed / Xposed 里改亮度的模块打架** | 同上。勾了 SystemUI / framework 的亮度相关模块时尤其要注意。 |
| **第三方 Recovery 刷不进去** | 包里没有 `META-INF/`，Recovery 会直接报错退出。只能走 Magisk。 |
| **Magisk 版本过低** | 需要 v30.6+。更老的版本 `resetprop` / `magisk --install-module` 行为不同。 |

### 二、安装与开机

| 可能的问题 | 说明 / 处理 |
| --- | --- |
| **第一次开机变慢，或停在启动动画** | `post-fs-data.sh` 在系统早期执行。若卡住，用 Recovery 删掉 `/data/adb/modules/ese_sku_fix` 或 `/data/adb/modules/outdoor_hbm_fix`。这两个模块本身不会让系统起不来，但**任何**模块出问题都应该这么救。 |
| **装完没效果** | 两个模块都要**重启**才生效。`outdoor_hbm_fix` 是常驻 `service.sh` 循环；`ese_sku_fix` 的 `resetprop` 必须在 `post-fs-data` 阶段跑。 |
| **`magisk --install-module` 报「不是 Magisk 模块」** | 发布的 zip 是 DEFLATE 压缩的。自己重新打包时注意 Magisk **只认 `compress_type` 0(STORED) / 8(DEFLATE)**，用 XZ / 7z / LZMA 压缩会直接被拒。 |

### 三、运行期的行为与观感

| 可能的问题 | 说明 / 处理 |
| --- | --- |
| **接管期间自动亮度会被临时关掉** | 为了让框架停止写入，模块会切到手动亮度并把滑块停在满格，**持续 = 强光 / 户外 / HDR 期间**。副作用：这段时间「自适应亮度」图标是关的；而且框架的自动亮度学习模型可能把这几次满格当成你的偏好，之后室内亮度可能略微偏高。释放时会把原值还原。 |
| **刚从暗到最亮那一下有明显阶跃** | 420 → 800 nits 是硬件的物理阶跃，原厂开 HBM 也是这个观感。这里只能保证它是**单调一次上升**，不是闪。 |
| **HDR 期间亮度滑块依旧无效** | 这是 ROM 框架的锅（映射表没配）。模块只能替你选一个固定值。动滑块模块会让位，但让位之后仍然只有 380 nits —— 除非重新进入 HDR。 |
| **让位之后短时间内不会再提亮** | 让位只在「同一触发条件」内有效。想立刻恢复提亮：关掉户外模式再开，或退出 HDR 页面再进。 |
| **在极暗环境下播 HDR 会非常亮** | 默认 HDR 目标就是 800 nits。夜里看片请把 `hdr_cap` 调小或设 0。 |
| **`hdr_cap` 写错内容** | 非数字 / 超过 486 的值会被忽略并回退到默认 486，不会报错。 |
| **模块中途被杀，亮度停在满格** | `saved_settings` 存档在模块目录里，下次模块启动（含开机）会自动把自动亮度开关和滑块还原。没重启就一直满格，手动拨一下滑块即可（模块会让位）。 |
| **熄屏瞬间的竞态** | 熄屏时模块直接跳过（不写节点）。极少数情况下熄屏瞬间写节点会失败，不影响后续。 |
| **`/data/local/tmp/outdoor_hbm.log` 有内容** | 正常。超过 64 KB 自清。想彻底静音可以把 `log()` 里的重定向删掉。 |

### 四、性能与耗电

| 可能的问题 | 说明 / 处理 |
| --- | --- |
| **常驻循环的 CPU 开销** | `service.sh` 每 ~0.4 秒一轮；非 HDR 状态下每 3 轮跑一次 `dumpsys SurfaceFlinger --hdr`（~80 ms）和一次 `dumpsys display`（~60 ms）。粗略量级**单核 5~8%**。日常使用无感，但会体现在待机耗电的零头上。 |
| **系统卡顿时 `dumpsys` 变慢** | 循环会跟着变慢；因为是串行的所以不会堆积。 |
| **激进省电 / 后台限制** | 这是 Magisk 的原生 `service.sh`（由 init 拉起，不是 app），通常不受省电策略影响；若 ROM 有额外限制，模块可能起不来。用 `ps -A \| grep outdoor_hbm` 确认。 |

### 五、长期硬件影响

| 可能的问题 | 说明 |
| --- | --- |
| **长时间最高亮度加速面板老化** | 800 nits 是这块屏的物理上限，长时间静态画面（尤其 UI 元素）在最高亮度下有**烧屏**风险。和原厂 HBM 行为的风险一致，但这里是你主动常开。 |
| **发热与热降亮度** | 面板高亮度下发热明显，框架的热降机制会介入，表现为用一会儿亮度自己掉下来 —— 那是保护，不是 bug。 |
| **Knox / warranty bit** | 刷这个 ROM 本身已经熔断 `warranty_bit`，装模块不会让它更糟。 |
| **eSE 修复的副作用** | `ese_sku_fix` 只是把 ROM 本来想要的 HAL 拉起来，正常没有副作用。理论上若某地区版本真的没有 eSE 硬件，拉起 HAL 后 NFC 安全元件类功能可能报错 —— 但 r8q 是有 eSE 的。 |

### 六、明确不支持的情况

- 用第三方 Recovery 直接刷 zip；
- 在 OneUI 7 / 其它 Android 版本上使用；
- 期望它修复「面板本身坏了 / 排线松动」这类硬件故障；
- 期望它解决相机 AI 功能缺失（那是 `/vendor/saiv` 被删导致的，与本项目无关）。

---

## 排障速查

| 现象 | 先查什么 |
| --- | --- |
| 完全没反应 | `ps -A \| grep outdoor_hbm` 有没有进程；`adb shell su -c 'cat /data/local/tmp/outdoor_hbm.log'` 有没有 `service started` |
| 亮度来回跳 | log 里 `corrected` 是不是刷屏 —— 是的话多半有别的模块 / 应用在抢同一个节点 |
| 一直最亮关不掉 | 确认 HDR 已退出：`dumpsys SurfaceFlinger --hdr \| grep numHdrLayers \| tail -1` 最后一条应为 `numHdrLayers(0)`；若仍是 `(1)` 说明还有 HDR 图层 |
| 只有 380 nits | HDR 路径没触发：确认图层宽度 ≥ 700 px，或直接看 log 有没有 `engage (hdr)` |
| 户外模式还是变暗 | `settings get system display_outdoor_mode` 是否为 1；log 有没有 `engage (outdoor)` |
| 卡死重启还在 | `ese_sku_fix` 没生效：跑一遍 [验证](#验证) 的三条命令 |

更细的抓取命令见 [`docs/diagnostics.md`](docs/diagnostics.md)。

## 目录结构

```
.
├── ese_sku_fix/        # 模块 1 源码（可直接作为 Magisk 模块目录）
│   ├── module.prop
│   ├── post-fs-data.sh
│   ├── service.sh
│   └── uninstall.sh
├── outdoor_hbm_fix/    # 模块 2 源码
│   ├── module.prop
│   ├── service.sh
│   └── uninstall.sh
├── docs/
│   └── diagnostics.md  # 排障用的原始命令
├── tools/
│   └── build.sh        # 打包成 dist/*.zip
├── LICENSE             # GPL-3.0
└── README.md
```

## 自己打包

```bash
bash tools/build.sh          # 输出到 dist/
```

需要 `zip`（Linux / macOS 自带；Windows 用 Git Bash）。

## License

[GPL-3.0](LICENSE)

---
---

# English

## What this is

Not a generic module. These are patches for **three specific defects in one specific port**, each derived from logs and sysfs data captured on the device rather than guesswork.

> ⚠️ Read [Possible problems](#possible-problems) first. None of them are hypothetical — they are the inherent trade-offs of this approach.

## Compatibility

| Item | Value |
| --- | --- |
| Device | Samsung Galaxy S20 FE 5G, codename **r8q** (verified on SM-G7810, CSC TGY) |
| ROM | **MintOS 1.0.0-Paradigm** — OneUI 8.0 / Android 16 / SDK 36, base `S916BXXU8EYI5` |
| Root | Magisk **30.6+** (verified on v31.x) |
| Backlight node | `/sys/class/backlight/panel0-backlight/brightness`, `max_brightness = 486` |

**Verified on this ROM and this device only.** There is no model/ROM guard in the code; installing it elsewhere is likely to cause new problems rather than fix anything.

## Modules

| Module | Version | Fixes | Reboot needed |
| --- | --- | --- | --- |
| [`ese_sku_fix`](ese_sku_fix/) | v1.0 | eSE HAL never starts → `com.android.se` blocks forever → ANR → freeze → reboot | Yes |
| [`outdoor_hbm_fix`](outdoor_hbm_fix/) | v16.0 | Outdoor mode making the screen darker / dim sunlight / HDR pinned at 380 nits | Yes (first install) |

They are independent — install either one on its own.

---

## ese_sku_fix — fixes random freezes and reboots

### Symptom

The phone gets sluggish, then the screen freezes completely, then it reboots on its own after ~10 seconds. `/data/system/dropbox/` gets one of these every 1–3 minutes:

```
system_app_anr: executing service com.android.se/.SecureElementService, waited 213579ms
```

### Root cause

The port gates the HAL on a property that does not exist on this device:

```
on property:ro.boot.hardware.sku=s3fwrn5
```

`ro.boot.hardware.sku` is **empty** on r8q, so `vendor.secure_element_hal_service-gto` never starts, `ISecureElementService` never registers, `com.android.se` waits forever, and the watchdog reboots the system.

### Fix

[`post-fs-data.sh`](ese_sku_fix/post-fs-data.sh):

```sh
resetprop ro.boot.hardware.sku s3fwrn5
```

[`service.sh`](ese_sku_fix/service.sh) starts the HAL as a fallback if it is somehow not running.

### Verify

```bash
adb shell su -c 'getprop ro.boot.hardware.sku'                                # expect s3fwrn5
adb shell su -c 'getprop init.svc.vendor.secure_element_hal_service-gto'      # expect running
adb shell su -c 'ls -lt /data/system/dropbox | head'                          # no new system_app_anr
```

---

## outdoor_hbm_fix — fixes brightness

### Symptoms

1. **Auto-brightness in sunlight is dim**, while manually dragging the slider to 100% is fine;
2. **Enabling Outdoor mode makes the screen darker**; it looks brightest around 60%;
3. **HDR video is dim and the brightness slider does nothing at all**.

### The panel's actual capability

`/sys/devices/virtual/lcd/panel/brt_avg` reports real output in nits:

| sysfs `brightness` | Actual output |
| --- | --- |
| 255 (the framework's "100%") | ~420 nits |
| 486 (`max_brightness`) | **~800 nits** |

So **the framework only ever uses 52% of the panel**. `mBacklightMaximum` is `1.9058824` (== 486), but the `screen_brightness` setting is capped at 255; everything above that has to go through HBM — and this port reports:

```
saveBrightnessInfo: brt:0.3764706 adjBrt:3.6323876 min:0.0 max:1.0 hbm:0
```

`hbm:0` means **HBM is never enabled**, so the 486 headroom is simply unreachable.

### Why each defect happens

**① Outdoor mode gets darker**

The framework does ask for 486 (`1.9058824`) — the log even claims `nits=800.0` — but `max:1.0 / hbm:0` clamps it, and Samsung's own scaler maps the excess down to **26**.

**② Sunlight stays dim**

The auto-brightness curve tops out around 3000 lux (~380 nits). Combined with `hbm:0`, stronger light cannot raise it any further.

**③ HDR is pinned**

The HDR mapping tables in `dumpsys display` are unconfigured:

```
mHdrBrightnessData = HdrBrightnessData { ... sdrToHdrRatioSpline: null,
                                         sdrToHdrSpline: null,
                                         highestHdrSdrRatio: 1.0,
                                         transitionPoint: 1.0 }
```

The framework cannot compute how bright the HDR content should be, so it uses a constant `mBrightnessState = 0.91930795` (== 234 → **380 nits**) and ignores the slider entirely. Measured: sweeping the slider from 10% to 100% leaves sysfs at 234 the whole time.

### Why early versions flickered

The first version wrote 486 straight to sysfs while `DisplayPowerController` was *still animating* towards its own, much lower target. Two writers interleaved on the same node — that is the "flickering while it climbs to full brightness":

```
17:43:13 engaged (lux=10956, was 5)
17:43:20 corrected 238 times     ← overwritten 238 times in 1.5 s
```

It looked fine once it reached full brightness only because the framework's animator had finished by then.

### How v16 works

1. **Take the framework out of the picture first**: switch to manual brightness and park the slider at maximum, so the framework's own target becomes 255 and it stops animating downward;
2. wait for the sysfs value to settle (animator finished);
3. **ramp to the target in a single uncontested monotonic sweep**;
4. while holding, correct only a **stable** wrong value — never chase the animator;
5. engage/release are **debounced with hysteresis**, so a flickering lux reading cannot make the module flap;
6. on release, **write back the value the framework believes it has** — the framework skips its own write when its target is unchanged, which is exactly how the panel ended up stuck at 800 nits (or stuck dim during HDR);
7. **reconcile every ~2 s**, and only correct when the mismatch is stable and larger than 6 — normal brightness animations are untouched;
8. HDR detection reads **only the newest SurfaceFlinger event** and requires the layer to be at least 700 px wide (the dump is a *history*; trusting all of it makes the module think HDR never ends);
9. **stand-down**: the moment the user touches the slider or re-enables auto-brightness, the module backs off within 0.5 s.

### Measured results

| Scenario | Result |
| --- | --- |
| Enable Outdoor mode | `255 → 278 → 301 → … → 485 → 486`, eleven purely monotonic steps, no dip |
| Torch driving lux up and down | holds 486, no oscillation |
| Disable Outdoor mode | `486 → 463 → … → 256 → 255`, settings restored |
| HDR playback | 380 → **800 nits**, zero corrections over 40 s |
| Drag the slider during HDR | module stands down immediately, stops writing |
| Leave HDR | released back to the framework's value |

### Configuration

Optional file `/data/adb/modules/outdoor_hbm_fix/hdr_cap`, containing `0`–`486`; reboot to apply:

```bash
adb shell su -c 'echo 486 > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # default, 800 nits
adb shell su -c 'echo 420 > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # gentler, ~693 nits
adb shell su -c 'echo 0   > /data/adb/modules/outdoor_hbm_fix/hdr_cap'   # disable the HDR boost
adb shell su -c 'rm /data/adb/modules/outdoor_hbm_fix/hdr_cap'           # back to default
```

### Log

```bash
adb shell su -c 'cat /data/local/tmp/outdoor_hbm.log'
```

Truncated automatically past 64 KB. Line meanings: `engage (outdoor|lux=N|hdr)`, `release (...)`, `corrected (was N)` (occasional is normal; constant means something else is fighting), `sync N -> M` (panel reconciled against the framework), `user override (...) - standing down`.

---

## Install

**Magisk app**: push `dist/*.zip` to the phone → Magisk → Modules → Install from storage → reboot.

**Command line** (rooted):

```bash
adb push dist/ese_sku_fix-v1.0.zip /data/local/tmp/
adb shell su -c 'magisk --install-module /data/local/tmp/ese_sku_fix-v1.0.zip'
adb reboot
```

The zips have **no `META-INF/`**, so they can only be installed through the Magisk app or `magisk --install-module` — **not by flashing them in a third-party Recovery**.

## Uninstall

Remove them in the Magisk app, or:

```bash
adb shell su -c 'rm -rf /data/adb/modules/outdoor_hbm_fix'
adb reboot
```

Neither module writes to system partitions; nothing is left behind.

---

## Possible problems

### Compatibility and wrong-device installs

| Problem | Details / what to do |
| --- | --- |
| **Installing on another ROM or device breaks things** | The code hardcodes the `panel0-backlight` path, the `s3fwrn5` SKU and the `vendor.secure_element_hal_service-gto` service name. On another ROM those do not exist: `outdoor_hbm_fix` will keep writing a missing node (fails, spams the log) and `ese_sku_fix` may start a HAL that was deliberately not meant to run. **Uninstall before changing ROMs.** |
| **Behaves oddly after a ROM update** | An OTA or reflash overwrites `/vendor` and can change the preconditions. Re-run the three verification commands after every update. |
| **Conflicts with other brightness modules** | Anything else writing `/sys/class/backlight/panel0-backlight/brightness` or driving `screen_brightness` (other HBM modules, night-light/colour modules, some Good Lock components) will fight it — visible as brightness bouncing, or both stopping working. **Keep only one.** |
| **Conflicts with LSPosed/Xposed brightness hooks** | Same as above, especially modules hooking SystemUI or the framework. |
| **Cannot be flashed in a third-party Recovery** | No `META-INF/`, so Recovery aborts. Magisk only. |
| **Magisk too old** | Requires v30.6+. Older versions differ in `resetprop` / `magisk --install-module` behaviour. |

### Installation and boot

| Problem | Details / what to do |
| --- | --- |
| **Slower first boot, or stuck on the boot animation** | `post-fs-data.sh` runs very early. If it hangs, delete `/data/adb/modules/<id>` from Recovery — neither module should prevent booting, but that is the standard escape for any module. |
| **No effect after installing** | Both modules need a **reboot**. `outdoor_hbm_fix` is a long-running `service.sh` loop; `ese_sku_fix`'s `resetprop` must run in `post-fs-data`. |
| **`magisk --install-module` says "not a Magisk module"** | Our zips use DEFLATE. If you repack them yourself, Magisk **only accepts `compress_type` 0 (STORED) or 8 (DEFLATE)** — XZ / 7z / LZMA archives are rejected outright. |

### Runtime behaviour and side effects

| Problem | Details / what to do |
| --- | --- |
| **Auto-brightness is temporarily switched off while engaged** | To stop the framework from writing, the module switches to manual brightness with the slider parked at maximum, **for as long as the high-light / Outdoor / HDR condition lasts**. Side effects: adaptive-brightness appears off during that time, and the framework's brightness learning model may treat those maxed-out samples as your preference, so indoor brightness can end up slightly higher afterwards. The original values are restored on release. |
| **A visible step when it snaps to full brightness** | 420 → 800 nits is a physical step; stock Samsung does the same when HBM engages. The module only guarantees it is one **monotonic rise**, not a flicker. |
| **The slider still does nothing during HDR** | That is the ROM's missing configuration. The module can only pick one fixed value for you. Touching the slider makes it stand down, but after standing down you are back to 380 nits until you re-enter HDR. |
| **No re-boost for a while after standing down** | Standing down applies to the same trigger. To get the boost back immediately, toggle Outdoor mode off/on or leave and re-enter the HDR page. |
| **Very bright when watching HDR in a dark room** | The default HDR target is 800 nits. Lower `hdr_cap` or set it to 0 for night viewing. |
| **`hdr_cap` containing junk** | Non-numeric or out-of-range values are ignored and fall back to 486. No error is raised. |
| **Module killed mid-engagement leaves the screen at full brightness** | The originals are stored in `saved_settings` inside the module directory and restored on the next module start (including boot). Until then, just nudge the slider — the module will stand down. |
| **Race with screen off** | The module skips everything while the screen is off; very rarely a write at the exact moment of screen-off fails. Harmless. |
| **`/data/local/tmp/outdoor_hbm.log` has content** | Expected. Self-truncates past 64 KB. Delete the redirection inside `log()` if you want it silent. |

### Performance and battery

| Problem | Details |
| --- | --- |
| **CPU cost of the polling loop** | One iteration every ~0.4 s; when not in HDR it runs `dumpsys SurfaceFlinger --hdr` (~80 ms) and `dumpsys display` (~60 ms) every third iteration. Roughly **5–8% of a single core**. Imperceptible in use, but it shows up in idle drain. |
| **`dumpsys` gets slower when the system is busy** | The loop slows down accordingly; it never backs up because the calls are serial. |
| **Aggressive power saving / background limits** | This is a native Magisk `service.sh` spawned by init (not an app), so it normally survives; if the ROM has extra restrictions the module may not start. Check with `ps -A \| grep outdoor_hbm`. |

### Long-term hardware impact

| Problem | Details |
| --- | --- |
| **Accelerated panel ageing** | 800 nits is the physical maximum. Long static content (especially UI elements) at full brightness carries a **burn-in** risk. Same risk as stock HBM behaviour, except here you are deliberately keeping it on. |
| **Heat and thermal throttling** | The panel gets noticeably warm at high brightness and the framework's thermal limits will step in — brightness dropping on its own after sustained use is protection, not a bug. |
| **Knox / warranty bit** | Flashing this ROM already tripped `warranty_bit`; installing modules does not make it worse. |
| **Side effects of the eSE fix** | `ese_sku_fix` only starts the HAL the ROM already expected; there are no normal side effects. If a variant genuinely lacked the eSE hardware, NFC secure-element features might log errors — r8q does have one. |

### Explicitly unsupported

- Flashing the zips in a third-party Recovery;
- OneUI 7 or any other Android release;
- Fixing hardware faults (dead panel, loose flex cable);
- Restoring the camera's AI features — those are missing because the port deletes `/vendor/saiv`, unrelated to this project.

---

## Troubleshooting

| Symptom | Check first |
| --- | --- |
| Nothing happens at all | Is the process alive: `ps -A \| grep outdoor_hbm`; does the log contain `service started` |
| Brightness keeps bouncing | Does `corrected` flood the log — if so, something else is writing the same node |
| Stuck at maximum brightness | Confirm HDR is really gone: `dumpsys SurfaceFlinger --hdr \| grep numHdrLayers \| tail -1` should be `numHdrLayers(0)` |
| Only 380 nits | The HDR path did not trigger: check the layer width is ≥ 700 px, or whether `engage (hdr)` appears in the log |
| Outdoor mode still darker | `settings get system display_outdoor_mode` should be 1, and `engage (outdoor)` should be in the log |
| Freezes still happen | `ese_sku_fix` is not active — run the three verification commands |

More detailed capture commands: [`docs/diagnostics.md`](docs/diagnostics.md).

## Repository layout

```
.
├── ese_sku_fix/        # module 1 sources (usable directly as a Magisk module dir)
├── outdoor_hbm_fix/    # module 2 sources
├── docs/diagnostics.md # raw commands used for diagnosis
├── tools/build.sh      # packages dist/*.zip
├── LICENSE             # GPL-3.0
└── README.md
```

## Building

```bash
bash tools/build.sh          # output in dist/
```

Requires `zip` (bundled on Linux/macOS; use Git Bash on Windows).

## License

[GPL-3.0](LICENSE)
