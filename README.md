# Kukusit · 坐姿监测

使用 MacBook 内置摄像头的本地坐姿监测应用。面向笔记本敞开、外接显示器位于上方的工作情境，不需要外接摄像头或手机。

## 安装

从 [GitHub Release v0.7.1](https://github.com/go1f/kukusit/releases/tag/v0.7.1) 下载 `Kukusit-0.7.1-macOS-arm64.dmg`，打开 DMG 后把 `Kukusit.app` 拖到 Applications。也提供 ZIP。安装后可从“应用程序”、Spotlight 或 Dock 启动，菜单栏入口继续保留。

发行包包含原生界面、本地 MediaPipe 推理运行时和模型，**无需安装 Python、无需克隆项目，也不需要联网推理**。目标为 Apple Silicon Mac，包括 M5 / macOS 27；当前已在 M2 / macOS 27 验证，尚未在 M5 实机测试。

当前发行包使用登录钥匙串中的本地开发证书自签名，未进行 Apple Developer ID 公证。macOS 可能拦截从网络下载的应用，请按“系统设置 → 隐私与安全性”中的系统提示手动允许。首次开始监测时，还需允许应用使用摄像头。

新电脑需要重新建立个人参考；发行包不包含原电脑的校准或摄像头画面。

## 日常使用

- 点击菜单栏图标，直接选择“打开监控窗口”，进入以居中视频为主的监控界面。
- “画中画”打开紧凑的小面板；右上角放大按钮返回主窗口。“更多”菜单控制摄像头、骨架、置顶和大小。
- 点击齿轮进入独立“设置”窗口。提醒、口部习惯、视频预览、校准与性能分别分组，高级诊断默认隐藏。
- “视频预览”的镜像设置同时作用于主窗口和 PiP，新安装默认关闭；已有保存选择保留。运行中的 Dock 图标跟随浅色/深色模式采用白底/黑底，Finder 使用透明兼容图标。
- 在正常看上方外接屏的舒适姿态下校准 20 秒。经常使用下屏时可以再建立下屏参考。
- 关闭窗口或收起 PiP 后继续监测；点击“暂停”才释放摄像头。

默认持续偏离 **5 秒 / 头部 3°** 才轻量提醒，回到 **1.5°以内并持续 2 秒** 才确认恢复。时间可调 1–120 秒，恢复、冷却、角度、识别频率和更多范围均在设置中调整并保存。提供更敏感/敏感/宽松预设及参数文件导入导出，不需要改代码或重新发版。头部、肩部和各种口部变化独立计时；一项恢复不清除其它项。持续异常的提示保留到确认恢复，默认静音、不抢键盘焦点；转头、离座或看不清时隐藏。定时自检与提醒样式预览仍在约 4 秒后消失。

“口部习惯”默认观察持续嘴角变化和手靠近嘴唇。歪嘴观察支持开口、嘴宽与上下唇不对称变化；需有效的个人自然参考。个人示范匹配用于你示范的紧咬、上唇/下唇动作、歪嘴或舌部动作外观：先录入自然放松 3 秒，再逐项录入动作 3 秒。每次要求至少 2 秒连续有效观察，距离或类别区分不足时保持安静；允许差距和区分裕度均可调整。只保存本机几何特征，新电脑需重新采样。

个人示范匹配是外观提示，不能确认咬合力量、具体牙位/舌头接触、磨牙或大小脸病因。另提供定时下颌自检及默认关闭的通用口唇/眼周变化试验。详见 [v0.6 监测与采样说明](docs/monitor-v0.6.md) 和 [完整架构审查](docs/architecture-review-v0.5.md)。

视频预览不等待推理。原生 Vision 可选自动/CPU/GPU/Neural Engine 优先；肩部是独立 CPU 进程，默认 3 Hz、640×360 分析输入。性能页显示实际脸部频率、推理延迟和本次摄像头首帧时间；设备偏好不保证每个阶段使用同一设备。

转头、离座、多个目标、低质量或过期观察都保持安静。关键点可用率不代表坐姿识别准确率，软件不测量颈椎角度或诊断疾病。

头部清晰时，肩部丢点不再中断歪头监测；肩线可靠且有肩部参考时才判断肩部。界面显示具体等待原因和“仅监测头部”的原因。偶发识别失败在 2 秒内保留已有计时，缺失期间不累计；超过 2 秒、明显转头、切换参考或多个目标会清除计时。短窗口中位数过滤偶发角度跳变，持续大幅抖动仍保持安静。上方屏幕允许更大的稳定俯仰变化，但俯仰本身不用于诊断坐姿。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools 和 Python 3.11+（已验证 Python 3.12）。

```sh
zsh scripts/setup_pose_backend.sh /absolute/path/to/python3.12
zsh scripts/build_pose_runtime.sh
zsh scripts/create_signing_identity.sh
zsh scripts/build_release.sh
zsh scripts/create_dmg.sh
zsh scripts/install_app.sh
```

输出为 `release/Kukusit.app` 和可下载的 ZIP。`build_release.sh` 将 Python 运行时冻结到应用内，配置中不保留开发机器的 Python 绝对路径。

开发界面版本可使用 `zsh scripts/build_app.sh --demo`。实际 Release 包通过以下检查：

```sh
swift run --build-system native PostureCoreChecks
release/Kukusit.app/Contents/MacOS/PostureDiagnostics --bridge-check
```

核心检查无需 XCTest 或完整 Xcode。当前 Swift 6.4 的原生构建参数用于仅有 Command Line Tools 的环境，会提示未来弃用；尚未对其它构建工具版本做保证。

## 隐私与仓库内容

图像只在本机内存和私有进程管道中处理，不保存照片、录像或上传画面。个人参考保存在应用自己的 Application Support，设置保存在 UserDefaults。源码仓库不上传 `.venv-pose`、本机模型缓存、个人校准及实拍验证记录。

## 文档

- [v0.7.0 原生自动检查与更新](docs/release-v0.7.0.md)
- [v0.6.0 独立计时、持续提示与个人口部示范](docs/release-v0.6.0.md)
- [v0.6 口部采样与能力说明](docs/monitor-v0.6.md)
- [v0.5.0 可调提醒、独立视频与口部习惯](docs/release-v0.5.0.md)
- [v0.5 全盘架构审查与能力边界](docs/architecture-review-v0.5.md)

- [v0.4 发布与布局更新](docs/release-v0.4.md)
- [v0.4.1 应用与菜单栏图标](docs/release-v0.4.1.md)
- [v0.4.2 透明应用图标与实心菜单栏图标](docs/release-v0.4.2.md)
- [v0.4.3 判定可用性与具体状态](docs/release-v0.4.3.md)
- [v0.4.4 轻微歪头阈值与恢复范围](docs/release-v0.4.4.md)
- [原生常驻设计 v0.3](docs/monitor-v0.3.md)
- [诊断原型 v0.2](docs/mvp-v0.2.md)
- [初版架构](docs/architecture-v0.1.md)
- [第三方组件与许可](THIRD_PARTY_NOTICES.md)

### v0.6.1 修复

镜像偏好在摄像头启动及重新连接后重新应用；应用图标改为原始姿态人形，状态栏保留坐姿小兽。

### 自动检查和更新

0.7.0 起可在应用菜单、状态栏面板或“设置 → 应用更新”检查新版，默认每天自动检查，安装由你确认。0.6.x 需要手动安装一次 0.7.1。更新保留镜像、敏感度、校准与个人示范。发布维护见 [更新说明](docs/updating.md)。
