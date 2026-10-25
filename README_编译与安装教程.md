# AirDepth动捕 (`AirDepthMocap`) — iPhone Air 原生前置 TrueDepth 深度 + 52表情 + 上半身3D动作控制律录制 App

本工程专为 **没有 Mac / Xcode 的 Windows 用户 + iPhone Air** 打造，直接调用 iPhone Air 前置 **TrueDepth 原深感红外摄像头 + Apple 神经网络引擎 (Vision)**，同步离线录制：
1. **`rgbd_side_by_side.mp4`**：左半屏 RGB 高清画面 + 右半屏实时硬件 **TrueDepth 红外深度伪彩视频**
2. **`depth_raw_16bit_mm.bin`**：无损 **16-bit 毫米级 (`uint16`, 1 单位 = 1 mm)** 逐帧原始红外深度矩阵流
3. **`livelink_face_52blendshapes.csv`**：100% 兼容 Unreal Engine 5 官方 **Live Link Face** 的 52 个 ARKit 表情系数 + 头部/眼球旋转 CSV（可直接拖入 UE5）
4. **`upper_body_control_law.csv` & `metahuman_full_take.json`**：将前置 TrueDepth 硬件深度图与上半身 2D/3D 骨骼点通过相机内参反投影融合，实时解算 **MetaHuman 上半身骨骼三维欧拉角 $\boldsymbol{\theta}(t)$、角速度 $\boldsymbol{\omega}(t)$、角加速度 $\boldsymbol{\alpha}(t)$ 以及二阶 PD 动作控制律信号 $\mathbf{u}_{\text{PD}}(t)$**！

---

## 第一步：在 Windows 上免 Mac 云端自动编译 `.ipa`（约 3 分钟）

1. 在浏览器登录 GitHub，打开 [https://github.com/new](https://github.com/new) 创建一个新的 **Public（公开）** 空仓库（公开仓库的 GitHub Actions `macos-15` 云服务器完全免费）。
2. 双击运行本目录下的 **`一键推送GitHub云编译IPA.bat`**，粘贴你刚创建的 GitHub 仓库地址并回车。
3. 打开你的 GitHub 仓库网页，点击顶部菜单栏的 **`Actions`**：
   - 你会看到 **`Build iPhone Air TrueDepth Mocap IPA`** 正在云端 macOS + Xcode 16 服务器上自动编译。
   - 约 **2~3 分钟** 变成绿色对勾 ✅ 后，点进去滑到最底部 **`Artifacts`** 区域，点击下载 **`AirDepthMocap_iPhoneAir_IPA`**，解压即可得到 **`AirDepthMocap_iPhoneAir_Unsigned.ipa`**！

---

## 第二步：在 Windows 上把 `.ipa` 安装到 iPhone Air

1. 在这台 Windows 电脑上下载并打开免费自签名工具 **Sideloadly**（官网：[https://sideloadly.io/](https://sideloadly.io/) ，需确保电脑装有非微软商店版 iTunes 和 iCloud）。
2. 用数据线将 **iPhone Air** 连接到电脑，在手机上点击“信任此电脑”。
3. 在 Sideloadly 界面中：
   - 左上角 `IPA` 图标：拖入刚才下载解压出的 **`AirDepthMocap_iPhoneAir_Unsigned.ipa`**。
   - `Apple ID` 输入框：输入你自己的任意免费 Apple ID 账号。
   - 点击 **`Start`** 按钮，等待约 20 秒即可安装到 iPhone Air 桌面（图标名称为 **“AirDepth动捕”**）。
4. **首次打开设置**：
   - 在 iPhone Air 上打开 **设置 -> 通用 -> VPN 与设备管理**，点击你的 Apple ID 并选择 **“信任”**。
   - 打开 **设置 -> 隐私与安全性 -> 开发者模式**，开启开发者模式并重启手机确认。

---

## 第三步：在 iPhone Air 上录制表情 + 上半身深度与动作

1. 打开手机上的 **「AirDepth动捕」** App，允许摄像头权限。
2. 将手机架在距离你 **35cm ~ 95cm** 处（顶部状态栏的 **`头距`** 会变成绿色，代表处于前置 TrueDepth 红外点阵最高精度甜点区，同时画面能拍到你的头部和上半身双臂）。
3. 界面会实时显示：
   - 面部 **1,220 顶点 3D 硬件网格 (`ARSCNFaceGeometry`)**
   - 上半身 **3D 骨骼连线**
   - 右下角实时 **TrueDepth 红外深度图小窗**
   - 左下角实时 **ARKit 52 表情系数条**
4. 点击底部红色圆形按钮开始录制，做出你的表情和上半身动作，再次点击停止录制。

---

## 第四步：导出数据到 Windows 并导入 UE5 MetaHuman

### 方式 A：直接从手机隔空投送 / 微信 / 文件 App 导出
- 点击 App 右下角 **「动作库」** 按钮，点击任意一条录制记录右侧的分享图标，或直接打开 iPhone 自带 **「文件 (Files)」App -> 我的 iPhone -> AirDepth动捕 -> Takes**，将 `Take_YYYYMMDD_HHMMSS` 文件夹发送到电脑。
- 也可以用数据线连接电脑，在 **爱思助手 / iTunes -> 应用 -> 文件共享 -> AirDepth动捕** 中直接把 `Takes` 文件夹拖到电脑桌面！

### 方式 B：在 Windows 端解包 16-bit 深度矩阵与辨识动作控制律
在 Windows 终端中运行：
```powershell
python "C:\Users\Admin\Desktop\AirDepthMocap\pc_tools\unpack_truedepth_take.py" "你的Take文件夹路径"
```
它会把 `depth_raw_16bit_mm.bin` 解包为标准的 NumPy 毫米级深度张量 `depth_metric_mm.npz`，并自动拟合出每个上半身关节的二阶 PD 控制律参数 ($K_p, K_d, \omega_n, \zeta$)，生成 `ue5_metahuman_ready.json`。

### 方式 C：一键导入 Unreal Engine 5 驱动 MetaHuman
1. **原生表情导入**：直接将 `Take` 文件夹里的 `livelink_face_52blendshapes.csv` 拖入 UE5 内容浏览器即可。
2. **表情 + 上半身 3D 骨骼同轨自动打帧**：
   - 在 UE5 中打开包含 MetaHuman 的 `Level Sequence`（保持 Sequencer 窗口开启）。
   - 打开 `pc_tools/ue5_import_metahuman.py`，将 `TAKE_JSON_PATH` 改为你的 `metahuman_full_take.json` 路径。
   - 在 UE5 菜单栏点击 **`Tools -> Execute Python Script...`** 运行 `ue5_import_metahuman.py`，即可一次性把 **52 个面部表情 + 上半身 3D 骨骼动作控制律** 全部写入 MetaHuman 的 `Face_ControlBoard_CtrlRig` 和 `Body_ControlRig`！
