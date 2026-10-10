# Kukusit v0.4.2

- 应用图标使用用户提供的坐姿小兽，去除白色背景，保留角色和椅子。所有 ICNS 尺寸保留透明通道，构建时不再铺白底。
- 菜单栏图标替换为用户指定的 `seated-mascot-white-filled-v4.svg`，保留实心轮廓及透明五官细节。继续使用 macOS 模板图标，自动适配深浅色菜单栏。

发布文件：`Kukusit-0.4.2-macOS-arm64.zip` 及 SHA-256 校验文件。解压后将 `Kukusit.app` 拖到“应用程序”，替换旧版。发行包包含本地推理运行时，无需安装 Python。支持 Apple Silicon Mac，最低 macOS 14；本版在 M2 / macOS 27 验证，尚未在 M5 实机测试。

验证包括图标透明通道、各尺寸 ICNS、菜单栏模板图标渲染、应用签名和内置姿态引擎。应用为 ad-hoc 签名，未进行 Developer ID 公证。
