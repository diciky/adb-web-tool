# ADB Web 远程管理工具（安卓 TV 4.0–9.0）

一个基于 **Node.js + adbkit** 的后端 + **Vue3 + Vite** 前端的 H5 Web ADB 工具，部署在 NAS / Docker 上常驻运行，通过浏览器（手机 / 电脑 / 盒子自带浏览器）远程管理局域网内的安卓 TV 设备。

---

## 一、已实现的核心功能

| 模块 | 功能 |
| --- | --- |
| 设备 / 扫描 | 局域网端口扫描（默认 5555，可配置），发现开启网络 ADB 的电视；手动输入 IP:端口 连接；查看已连接设备与详情（型号 / 安卓版本 / IP / 序列号）；断开连接 |
| 应用管理 | 读取应用列表（区分用户 / 系统应用、是否停用）；**完整识别应用名称与图标**（解析 APK 的 resources.arsc & 二进制清单）；启动应用、强制停止、清除数据、导出 APK、卸载 |
| 安装 APK | 拖拽 / 选择 APK（支持多选），自动推送到所选设备并安装，实时进度（上传 + 安装阶段） |
| 文件传输 | 浏览目录、新建文件夹、上传文件（含进度）、下载文件、删除文件 / 文件夹；适合向安卓 TV 推送视频、字幕、配置文件等 |
| 工具箱 | 远程截图（PNG）、虚拟遥控器（方向键 / 主页 / 返回 / 菜单 / 音量 / 电源等）、文本输入、唤醒 / 熄屏、重启 / 进 Recovery / 关机、实时 Logcat 日志、Shell 终端 |
| 屏幕镜像 | 基于循环 `screencap` 的 MJPEG 实时预览（兼容 Android 4.0+，无需额外组件），支持画笔 / 矩形 / 箭头 / 文字 **远程标注**，可导出标注图或推送到设备 |
| 屏幕录制 | 调用设备自带 `screenrecord` 录制 MP4（Android 4.4+），可设时长上限，录制完直接下载 |
| 自启管理 | 列出声明 `RECEIVE_BOOT_COMPLETED` 的应用，单独开关其开机广播接收器；厂商管家不可解析时提供「禁用整个应用」兜底 |
| 批量 / 定时 | 批量对多设备执行 重启 / 卸载 / 清数据 / 安装 APK 等；定时任务支持「固定间隔(秒)」或「Cron 表达式」，服务端持久化与自动执行 |
| 健康监控 | 实时采集 CPU / 内存 / 存储 / 电池 / WiFi 速率，前端折线图 + 进度条可视化（每 2s 采样） |
| 网络测速 | Ping 延迟与丢包、局域网推送/拉取吞吐（MB/s）、WiFi 速率与信号强度 |
| 中文输入 | 通过剪贴板方式输入中文/任意文本（优先 Clipper 应用，回退 `service call`，再回退 ASCII）；可选「复制并粘贴」 |
| 远程标注 | 在实时镜像画面上叠加标注图层，用于远程指引，可导出 PNG 或发送到设备 |

> 兼容性：基于 adbkit 的协议兼容处理，覆盖 Android 4.0（Ice Cream Sandwich）到 9.0（Pie）。系统应用卸载优先尝试 `--user 0` 隐藏方案以兼容多用户机制。屏幕录制依赖设备自带 `screenrecord`（部分 TV 厂商已移除该命令时会提示不可用）。

---

## 二、仍可继续扩展的方向（注释版）

以下功能在当前架构上**可低成本扩展**，按需取舍：

```
1. 真·高帧率镜像 —— 引入 scrcpy / ffmpeg 将设备视频流解码为 H5 <video>，替代当前 1~3fps 的 screencap 轮询方案
2. 应用权限审查 —— 解析 dumpsys package 的 requested permissions，列出敏感权限应用
3. 应用冻结 / 启用切换 —— 基于 pm disable-user / enable 系统接口
4. 设备分组 / 标签 —— 多 TV 场景下按房间分组管理
5. 安卓 11+ 无线调试配对码连接（adb pair / mDNS）—— 适配新协议
6. 远程文件自动同步 —— 监听本地目录变化推送到 TV
7. 微信 / 钉钉 / 邮件 告警 —— 设备离线、安装失败、定时任务异常通知
8. OTA / 固件升级辅助 —— 推送 update.zip 并触发 recovery 升级
9. 多用户 / 儿童模式切换 —— 切换 foreground user
10. 标注实时同步到电视屏幕 —— 当前标注为本地叠加层，可进一步将标注图叠加显示为设备端悬浮窗
```

---

## 三、部署

### 方式 A：Docker Compose（推荐，NAS 常驻）

```bash
# 1. 准备配置（可选）
cp .env.example .env
# 编辑 .env：设置 ACCESS_TOKEN（建议）、SCAN_PORTS、SUBNETS 等

# 2. 构建并启动
docker compose up -d --build

# 浏览器访问 http://<NAS_IP>:8877
```

> 若扫描不到同网段设备（Docker 桥接 NAT 限制），可将 `docker-compose.yml` 中的
> `network_mode: host` 取消注释（Linux 宿主有效）。

---

## 四、通过 GitHub Actions 自动构建并推送 Docker Hub

仓库已内置 `.github/workflows/docker.yml`，在推送代码到 `main`/`master` 或手动触发时，自动构建 `linux/amd64` + `linux/arm64` 镜像并推送到 Docker Hub。

使用步骤：
1. 将本项目推送到你的 GitHub 仓库。
2. 仓库 **Settings → Secrets and variables → Actions** 添加两个密钥：
   - `DOCKERHUB_USERNAME` = 你的 Docker Hub 用户名（例：`diciky`）
   - `DOCKERHUB_TOKEN` = Docker Hub 访问令牌（Account Settings → Security → New Access Token）
3. 推送代码（或到 Actions 页手动 Run workflow）。
4. 构建完成后镜像为：`docker.io/<DOCKERHUB_USERNAME>/adb-web-tool:latest`（例：`diciky/adb-web-tool:latest`）。

> 拉取运行：`docker run -d -p 8877:8877 -v $(pwd)/data:/data diciky/adb-web-tool:latest`
> NAS 用户可用 `docker-compose.yml`（已默认端口 8877）。

### 方式 B：本地直接运行

```bash
# 需要本机已安装 platform-tools（adb 在 PATH 中）
cd server && npm install && npm start

cd ../web && npm install && npm run dev   # 开发前端 http://localhost:5173
# 生产：npm run build 后由后端静态托管
```

---

## 四、使用前置条件

1. 安卓 TV 已开启「开发者选项 → USB 调试」与「网络 ADB 调试 / 无线调试」。
2. TV 与运行本工具的主机处于同一局域网。
3. 首次连接需在 TV 屏幕上点击「允许 USB 调试」授权（RSA 密钥会缓存于 `DATA_DIR`，重启服务无需重复授权）。
4. 安装 APK 需在 TV 上允许「未知来源应用」。

---

## 五、接口与扩展开发

后端提供 REST + WebSocket：
- REST：`/api/devices`、`/api/connect`、`/api/apps/:serial`、`/api/install/:serial`、`/api/files/:serial/*`、`/api/tools/:serial/*`
- WebSocket：`/ws`，推送扫描结果、安装 / 上传进度、Logcat 与 Shell 数据
- 局域网扫描：`POST /api/scan { subnet }`，可选 `SUBNETS` 环境变量预置

环境变量：`PORT`、`DATA_DIR`、`UPLOAD_MAX_MB`、`SCAN_PORTS`、`SUBNETS`、`ACCESS_TOKEN`、`PULL_MAX_BYTES`（解析名称时拉取 APK 的大小上限，避免超大游戏包拖垮服务）。
