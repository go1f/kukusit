# 可行性验证 v0.1

日期：2026-10-09（Asia/Shanghai）。结论：**单机原生软件路线具备已验证的接口基础；当前摆放下的识别可用率、误报和功耗尚未验证。**

## 1. 验证环境与方法

本机为 MacBook Air（Mac14,2），Apple M2、8 核、16 GB 内存；macOS 27.0.1，Swift 6.4。探针按 macOS 14 的部署目标编译并在当前系统执行，未在 macOS 14 真机上测试。

检查分为三类：系统和设备只读枚举；Apple Vision 在合成空白图像上的运行；人工构造的几何与时间序列验证。未开始摄像头采集、未申请权限、未保存个人图像。摄像头权限查询返回 `notDetermined`，该结果属于本次探针的执行身份，不代表所有应用的相机权限状态。

## 2. 本机已验证结果

| 项目 | 观察结果 | 能支持的结论 |
|---|---|---|
| 内置摄像头发现 | `FaceTime高清相机`；内置广角设备类型；连接且未挂起 | 可以用设备类型明确选择内置摄像头 |
| 视频格式 | 640×480、1280×720、1920×1080 等；枚举到的代表格式范围 15–30 FPS | 720p／15 FPS 是可请求的首版起点，仍需采集验证实际送帧 |
| 二维身体关键点 | 当前请求支持 19 个点，包含左右肩、颈、眼、耳等 | 所需点的接口存在；不保证当前机位能稳定识别 |
| 手部关键点 | 当前请求支持 21 个点 | 可以实现手部观察；接近嘴部不等于咬手指 |
| 面部与身体请求 | 脸框 revision 3、脸部关键点 revision 3、身体 revision 1、手部 revision 1 全部执行完成 | 本机运行时兼容；空白图像结果均为 0 人／0 手，符合预期 |
| 外接屏 | U27U2D，当前为主显示器，1920×1080 点、2× 缩放 | 可明确选定提醒屏幕，需区分点与像素 |
| 内置屏 | 1280×832 点、2× 缩放 | 可提供外接屏断开时的回退 |

显示器的逻辑排列也已确认：外接屏 AppKit frame 原点为 `(0,0)`，内置屏原点为 `(291,1080)`。AppKit 的 y 轴向上，这表示系统把内置屏放在外接屏上方，和用户描述的物理摆放相反。提醒可按设备身份选择外接屏，不需要改用户的系统设置，也不能从这些坐标推断人的真实注视方向。

SDK 核实还发现 `AVCaptureDevice.Format.videoFieldOfView` 不可用于 macOS；本次没有测量镜头视场角、实际拍摄距离或屏幕开合角度。相关几何分析不使用虚构的相机参数。

## 3. 合成几何与时间验证

### 3.1 归一化坐标造成角度误差

在 1280×720 画面内，假设肩线水平差 360px、垂直差 36px：

| 计算方法 | 结果 |
|---|---:|
| 正确：`atan2(36, 360)` | 5.7106° |
| 错误：`atan2(36/720, 360/1280)` | 10.0806° |
| 归一化结果先恢复像素尺度再计算 | 5.7106° |

所以特征计算必须考虑 W／H，不能直接对归一化点求欧氏角度。若将错误结果与 8° 的进入阈值比较，同一个示例会被错误判为超阈值。这是数学验证，不是模型误报率测量。

### 3.2 探颈与整个人靠近的混淆

假设简化针孔模型与固定朝向，脸部从相机前 70cm 移到 60cm，像素尺度放大约 `70/60 = 1.1667`。整个人靠近时脸和肩都会放大；头部独立靠近时可能主要放大脸。因此脸宽／肩宽比例可以作辅助特征。

但相同二维投影可以对应不同深度关系，人体旋转、仰拍、相机角度变化也会改变比例。由此推导：只能输出“疑似头部相对靠近”，不能单凭脸变大判断头前倾，更不能恢复精确颈部角度。示例距离是合成输入，与用户桌面的实际尺寸无关。

### 3.3 丢帧不能贡献异常持续时间

以 6 Hz、12 秒提醒阈值验证最小时间累计原则：

- 异常约 3 秒：没有提醒。
- 连续异常约 20 秒：在第 12 秒产生一次确认。
- 异常 6 秒，空档 94 秒，再异常 6 秒：没有提醒。
- 异常 6 秒，中间为不可判定，再异常 6 秒：没有提醒。

四种检查均通过。示例实现只验证持续时间原则，不包含生产版的迟滞、冷却、目标关联和提醒去重；不能作为完整规则引擎直接使用。

## 4. 尚未验证的条件

| 待测条件 | 验证方式 | 失败后的选择 |
|---|---|---|
| 当前开合角度能否同时看清脸与双肩 | 原生诊断应用预览＋逐点质量；正常工作 2 分钟 | 先只开头部功能；确认裁切后再调整笔记本摆放 |
| 仰拍下头部角度是否稳定 | 上屏中心、四角、下屏、歪头与转头对照 | 扩大正常观看范围，限制 pitch／yaw 提醒，必要时比较后端 |
| 高低肩提醒是否有价值 | 人工标记动作，加入鼠标操作、整体侧倾和旋转负例 | 降级为肩线变化；髋部不可见时不区分躯干倾斜 |
| 手口接近是否频繁误报 | 托腮、喝水、说话、抬手和真正接近嘴部的时序测试 | 暂不启用通知，保留观察与反馈 |
| 常驻成本是否可接受 | 摄像头关闭／仅采集／采集＋推理各至少 20 分钟 | 先降低手部频率，再降低基础分析率，分别测采集耗电 |
| 提醒与系统状态 | 全屏、Space 切换、显示器拔插、锁屏、睡眠、会议 | 限定展示策略，必要时仅菜单栏显示，避免残留计时 |

本次未执行 MediaPipe，也未比较模型速度或准确率；未测 3D 身体请求在上半身裁切画面上的表现；未验证真实咬唇、咬牙识别。

## 5. 复现与证据文件

在项目根目录运行：

```sh
zsh probes/run_capability_probe.sh --smoke
python3 probes/geometry_and_time_checks.py
```

- `probes/capability_probe.swift`：只读能力枚举与空白图像运行检查，无外部库。
- `probes/run_capability_probe.sh`：编译到 `.build/` 后运行；标准输出为 JSON；框架诊断可能写到标准错误。
- `probes/geometry_and_time_checks.py`：标准库合成验证，断言失败会返回非零退出码。
- `validation/capabilities-2026-10-09.json`：本次最终探针输出。
- `validation/geometry-and-time-2026-10-09.json`：本次合成验证输出。

架构中的阈值、可判定比例与资源预算是后续验收目标，没有当作本次实测结果。

## 6. 官方依据

Apple 的二维姿态文档确认接口、置信度与归一化坐标规则；三维文档明确完整关节输出与深度信息的作用；面部 pitch 是可选字段。以上说明决定了适配层与降级处理，但不证明个体坐姿识别效果。

- [二维身体姿态](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images)
- [三维身体姿态](https://developer.apple.com/documentation/vision/identifying-3d-human-body-poses-in-images)
- [面部 pitch](https://developer.apple.com/documentation/vision/vnfaceobservation/pitch)
- [摄像头权限查询](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))
- [迟到帧丢弃](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/alwaysdiscardslatevideoframes)
- [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen) · [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)
- [MediaPipe 平台与任务](https://developers.google.com/edge/mediapipe/solutions/guide) · [Python 环境](https://developers.google.com/edge/mediapipe/solutions/setup_python)
