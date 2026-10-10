# Kukusit · 坐姿监测

使用 MacBook 内置摄像头的本地坐姿监测应用。面向笔记本敞开、外接显示器位于上方的工作情境，不需要外接摄像头或手机。

## 安装

从本仓库的 GitHub Releases 下载 `Kukusit-0.4.0-macOS-arm64.zip`，解压后把 `Kukusit.app` 拖到“应用程序”。运行时只显示菜单栏图标。

发行包包含原生界面、本地 MediaPipe 推理运行时和模型，**无需安装 Python、无需克隆项目，也不需要联网推理**。目标为 Apple Silicon Mac，包括 M5 / macOS 27；当前已在 M2 / macOS 27 验证，尚未在 M5 实机测试。

当前发行包使用 ad-hoc 签名，未进行 Developer ID 公证。macOS 可能拦截从网络下载的应用，请按“系统设置 → 隐私与安全性”中的系统提示手动允许。首次开始监测时，还需允许应用使用摄像头。

新电脑需要重新建立个人参考；发行包不包含原电脑的校准或摄像头画面。

## 日常使用

- 点击菜单栏图标，直接选择“打开监控窗口”，进入以居中视频为主的监控界面。
- “画中画”打开紧凑的小面板；右上角放大按钮返回主窗口。“更多”菜单控制摄像头、骨架、置顶和大小。
- 点击齿轮进入独立“设置”窗口。提醒、PiP、校准分别分组，高级诊断默认隐藏。
- 在正常看上方外接屏的舒适姿态下校准 20 秒。经常使用下屏时可以再建立下屏参考。
- 关闭窗口或收起 PiP 后继续监测；点击“暂停”才释放摄像头。

默认持续偏离 25 秒才轻量提醒，提示约 4 秒淡出，不抢键盘焦点、不发声音。回正不足 2 秒为“待确认恢复”，保留累计异常时间；重新偏离继续累计，连续回正满 2 秒才清零。仍未恢复时隔 3 分钟再提醒。

转头、离座、多个目标、低质量或过期观察都保持安静。关键点可用率不代表坐姿识别准确率，软件不测量颈椎角度或诊断疾病。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools 和 Python 3.11+（已验证 Python 3.12）。

```sh
zsh scripts/setup_pose_backend.sh /absolute/path/to/python3.12
zsh scripts/build_pose_runtime.sh
zsh scripts/build_release.sh
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

- [v0.4 发布与布局更新](docs/release-v0.4.md)
- [原生常驻设计 v0.3](docs/monitor-v0.3.md)
- [诊断原型 v0.2](docs/mvp-v0.2.md)
- [初版架构](docs/architecture-v0.1.md)
- [第三方组件与许可](THIRD_PARTY_NOTICES.md)
