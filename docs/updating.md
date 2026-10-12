# 检查与发布更新

Kukusit 0.7.0 开始使用原生更新实现。固定入口为 `https://github.com/go1f/kukusit/releases/latest/download/update.json`，公开 GitHub Release 不需要令牌。不加载 Sparkle 或其他动态更新框架，保留原 Hardened Runtime 与动态库验证。

用户可在应用菜单、菜单栏状态面板和设置的“应用更新”页检查版本。默认每天自动检查一次，可关闭并保留选择。后台发现新版后菜单栏增加一个小圆点，状态面板显示版本入口；不抢焦点。安装由用户确认，支持稍后再操作或跳过版本。网络故障时保留当前应用，可以重新手动检查。

更新流程：验证 Ed25519 签名的精确 manifest 字节 → 检查构建号、机型及 macOS 条件 → 下载 ZIP → 核验长度与 SHA-256 → 校验解压路径 → 验证应用完整签名、Bundle ID、固定证书与构建号 → 用户点击“安装并重新启动” → 独立助手等旧进程退出，在同一卷中重命名替换 → 重新打开应用。助手无管理员权限，不写个人数据目录；无法自动更新只读磁盘镜像或不可写目录。

替换、验证或重新打开失败会恢复原包。成功时上一版本保存在应用同目录 `.kukusit-update-UUID/previous.app`，可手动恢复。应用签名证书固定在 `UpdateInstallation.requirement` 中；未来更换证书需先发布能认可新证书的过渡版本。

设置仍在同一 UserDefaults 域，校准和个人示范仍在原 Application Support 目录。更新只传输更新信息和安装包请求，不发送图像、校准、示范或系统统计。

## 发布流程

1. 修改 `App/Info.plist` 显示版本和递增构建号，编写对应 `docs/release-vX.Y.Z.md`。
2. 运行 `zsh scripts/build_release.sh` 和 `zsh scripts/create_dmg.sh`。
3. 运行 `python3 scripts/build_update_manifest.py`。脚本在登录钥匙串中使用 Ed25519 私钥为 manifest 签名，生成 `release/update.json`。公开密钥在 Info.plist 的 `KukusitUpdatePublicKey` 中。
4. 上传 ZIP、DMG、校验文件与 `update.json` 到对应 GitHub Release；完成上传和匿名下载校验之后，将 Release 标为 latest。不要用缺少 `update.json` 的发布替换 latest。
5. 用应用 `--update-manifest-check release/update.json release/Kukusit-X.Y.Z-macOS-arm64.zip` 校验真实签名与包内容，并测试从低构建号安装至新构建号。

维护者的签名工具使用 Sparkle 2.10.0 官方 `sign_update`，仅在构建机运行，不包含在用户应用中。工具可放在 `.local/sparkle/bin/sign_update`；官方发布为 `https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz`。下载并在 `.local/sparkle` 解压后可用。首次需要系统钥匙串授权。新构建机需要安全迁移已有的钥匙串密钥；不要重新生成密钥替代已发布的公开密钥。

私钥不在源码、应用包或 GitHub 中。签名 payload 是 manifest 原始 UTF-8 JSON 的全部字节，envelope 中为 Base64 payload 和 detached Ed25519 signature。signature 必须使用 `--disable-signing-warning`，禁止改变 payload 后继续使用原签名。

## 一次性迁移

0.6.x 尚无更新器，需手动安装 0.7.0 一次。以后通过应用内检查与安装。自签名发布没有 Apple 公证，首次下载仍由 macOS 管理安全确认。
