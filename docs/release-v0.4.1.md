# Kukusit v0.4.1

- 应用图标换为用户提供的坐姿小兽原图，保留完整画面和白色背景。
- 菜单栏换为用户指定的白色小兽 SVG，按 macOS 模板图标渲染，适配深浅色菜单栏。
- 构建时从原图生成完整的 10 档 ICNS 图标，SVG 随应用一起打包。

发布文件：`Kukusit-0.4.1-macOS-arm64.zip` 及 SHA-256 校验文件。解压后将 `Kukusit.app` 拖到“应用程序”，再启动。支持 Apple Silicon Mac，最低 macOS 14；本版在 macOS 27 的 M2 Mac 上构建和验证。

验证包括原图及 SVG 一致性检查、ICNS 各尺寸读取、菜单栏 SVG 透明背景与模板渲染检查，以及应用签名和内置姿态引擎检查。应用为临时签名，未做 Developer ID 公证。
