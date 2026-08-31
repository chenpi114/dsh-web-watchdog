# dsh-web-watchdog — DeepSeek Harness Web GUI 守护方案

本地运行 DeepSeek Harness Web GUI（`http://127.0.0.1:3080`）时，服务进程被杀或崩溃后不会自动恢复，每次都要手动启动；而"每 N 分钟轮询一次"的看门狗又会在打游戏时周期性拉起进程，造成掉帧。

本仓库提供一套**常驻、事件驱动的守护方案**：

- 一个常驻看门狗进程，用 `WaitForExit()` 阻塞等待服务进程退出（**零 CPU 开销、无周期轮询**），服务死掉后自动拉起；
- 显式 `stop` 会写标记，看门狗尊重"故意停机"（直到再次 `start`）；
- 启动竞争（EADDRINUSE）已加固：本实例失败但端口已被占用时视为成功；
- 容忍 120 秒冷启动（插件树加载慢的机器不会误判失败）。

已在生产环境连续运行 11 天，8 次"服务退出→自动恢复"全部成功。

## 文件

| 文件 | 作用 |
|---|---|
| `dsh-web.ps1` | 服务管理脚本：`start` / `stop` / `restart` / `status` / `watchdog` |
| `dsh-web-watchdog.ps1` | 常驻看门狗（事件驱动，单实例互斥） |
| `install.ps1` | 一键部署：复制脚本、注册计划任务、创建开机自启、立即启动 |

## 安装

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

部署内容：

1. 复制脚本到 `%USERPROFILE%\.dsh`（可用 `-DshHome` 覆盖）；
2. 注册计划任务 `DSH-Web-Watchdog`：**登录时触发**，启动常驻看门狗（运行时长不限、防重复实例、允许电池供电）；
3. 启动文件夹创建 `dsh-web-autostart.vbs`：登录时后台启动服务；
4. 立即启动服务并确保看门狗在跑。

卸载：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

## 常用命令

```powershell
# 手动查看状态
powershell -File "$env:USERPROFILE\.dsh\dsh-web.ps1" -Command status

# 手动启动（清除 stop 标记 + 确保看门狗）
powershell -File "$env:USERPROFILE\.dsh\dsh-web.ps1" -Command start

# 故意停机（写 stop 标记，看门狗不会自动拉起；下次 start 恢复）
powershell -File "$env:USERPROFILE\.dsh\dsh-web.ps1" -Command stop
```

## 路径参数

`dsh-web.ps1` 支持参数覆盖默认值：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Node` | 自动探测 | node.exe 路径 |
| `-WorkDir` | 自动探测 | dsh 仓库根目录（探测顺序见下） |
| `-Port` | `3080` | 服务端口 |
| `-DshHome` | 脚本所在目录 | 日志/标记/看门狗所在目录 |

## WorkDir 自动探测

`-WorkDir` 不传时，按以下顺序探测 dsh 仓库根目录（特征文件 `apps\cli\src\bin.ts`）：

1. 环境变量 `DSH_WORKDIR`；
2. 从脚本所在目录向上逐级查找（脚本放在 dsh 仓库内时自动命中）；
3. 都没有时 `start` 会报错提示（`status` / `stop` 不受影响）。

脚本通过 `install.ps1` 部署到 `%USERPROFILE%\.dsh` 后（与 dsh 仓库分离），建议设置环境变量：

```powershell
setx DSH_WORKDIR "D:\path\to\deepseek-harness"
```

设置后需重新打开终端（或重启看门狗进程）生效；也可以每次调用时传 `-WorkDir`。

## FAQ

**Q：为什么不用"每 N 分钟的计划任务"来检查？**
进程周期性启动会产生 CPU/内存尖峰，落在游戏帧时间上就是掉帧；常驻进程平时完全静默，只在目标退出时行动。

**Q：杀掉服务后多久能恢复？**
看门狗检测到进程退出后立即重启，加上 120 秒冷启动容忍，通常 1~2 分钟内恢复；冷启动失败会退避重试（15s 起，上限 120s）。

**Q：重启时报 `EADDRINUSE` 怎么办？**
一般是双实例竞争端口。`Start-Web` 已加固：本实例失败但端口已被占用时视为成功，不会误报。
