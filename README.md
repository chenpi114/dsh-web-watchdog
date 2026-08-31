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
| `dsh-web-notify.ps1` | 自动恢复通知（托盘气泡，点击打开 GUI 并回到最新会话） |
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
3. 脚本同目录下的本机覆盖文件 `dsh-web.env.ps1`（**不入库**，内容为 `$WorkDir = '你的 dsh 仓库路径'`）；
4. 都没有时 `start` 会报错提示（`status` / `stop` 不受影响）。

脚本通过 `install.ps1` 部署到 `%USERPROFILE%\.dsh` 后（与 dsh 仓库分离），推荐二选一：

```powershell
# 方式 A: 环境变量(需要重新登录或重启终端生效)
setx DSH_WORKDIR "D:\path\to\deepseek-harness"

# 方式 B: 本机覆盖文件(立即生效, 不入库)
# 在 %USERPROFILE%\.dsh\dsh-web.env.ps1 里写一行:
#   $WorkDir = 'D:\path\to\deepseek-harness'
```

## 自动恢复通知与"继续之前的对话"

看门狗自动拉起服务后，会弹出一个托盘通知：

- 标题：`DeepSeek Harness 已自动恢复`，含重启时间和新 PID；
- **点击通知**会打开 GUI，并自动回到最新会话（深链 `?session=<会话ID>`）；
- 通知进程独立运行（不阻塞看门狗），30 秒无操作自动消失。

**自动"继续"**：如果被打断的对话轮次（崩溃时轮次未完成，host 恢复时会用合成事件闭合，特征为 `TOOL_OUTCOME_UNKNOWN` / `TOOL_NOT_STARTED` 错误码的工具结果），点击通知打开会话后**自动发送"继续"**，agent 直接接着干活，不用再手动输入。

前提：**深链支持（GUI 侧）**——DeepSeek Harness 前端需要支持 `?session=<id>` 参数。默认版本尚未内置，需要在本机 dsh 仓库打一个很小的本地补丁（约 40 行，未提交上游），核心逻辑在 `packages/client/web/src/app-shell.ts` 的 `apply()` 中（`ctx.slots.install(createSlotRenderer())` 之后）：

```ts
// 1) 深链: `?session=<id>` 在会话列表就绪且无当前会话时自动打开, 打开后清理 URL
// 2) 自动继续: 会话打开后, 若日志含 TOOL_OUTCOME_UNKNOWN / TOOL_NOT_STARTED
//    错误码的工具结果(被打断轮次的合成闭合特征)且 agent 空闲, 自动 prompt "继续"
const wanted = new URLSearchParams(globalThis.location.search).get('session')
if (wanted !== null) {
  ctx.effect(() => {
    const id = wanted as SessionId
    let prompted = false
    let unsubscribeSession: (() => void) | undefined
    const openWhenReady = (): void => {
      const state = ctx.sessions.list.getSnapshot()
      if (state.current === undefined && state.byId[id] !== undefined) {
        ctx.sessions.open(id)
        globalThis.history?.replaceState(null, '', globalThis.location.pathname + globalThis.location.hash)
      }
    }
    const continueIfInterrupted = (): void => {
      if (prompted) return
      const binding = ctx.sessions.binding(id)
      if (binding === undefined) return
      const snapshot = binding.session.getSnapshot()
      if (snapshot.openState !== 'open' || snapshot.running) return
      // 只检查最后一个用户消息之后的节点(最近一轮): 被打断轮次的合成闭合
      // 特征出现在最近一轮才自动"继续"; 旧轮次的残留标记不会反复触发
      let lastUserIndex = -1
      for (let i = 0; i < snapshot.nodes.length; i++) {
        if (snapshot.nodes[i].kind === 'user') lastUserIndex = i
      }
      const tail = lastUserIndex === -1 ? snapshot.nodes : snapshot.nodes.slice(lastUserIndex)
      const interrupted = tail.some((node) =>
        node.kind === 'tool-result' && node.isError
        && (node.error?.code === 'TOOL_OUTCOME_UNKNOWN' || node.error?.code === 'TOOL_NOT_STARTED'))
      if (!interrupted) return
      prompted = true
      void binding.session.prompt([{ type: 'text', text: '继续' }], 'queue')
    }
    const attachSession = (): void => {
      if (unsubscribeSession !== undefined) return
      const binding = ctx.sessions.binding(id)
      if (binding === undefined) return
      unsubscribeSession = binding.session.subscribe(continueIfInterrupted)
      continueIfInterrupted()
    }
    openWhenReady()
    attachSession()
    const unsubscribeList = ctx.sessions.list.subscribe(() => {
      openWhenReady()
      attachSession()
    })
    return () => {
      unsubscribeList()
      unsubscribeSession?.()
    }
  }, 'web: session deep link')
}
```

（还需在文件顶部加 `import type { SessionId } from '@deepseek-ai/dsh-client-runtime/client'`。）

然后重建前端（静态文件，**无需重启服务**，刷新页面即生效）：

```powershell
cd <dsh 仓库根目录>
pnpm run build:web
   ```

2. **浏览器标签页开着时**：前端自带自动重连（指数退避），服务恢复后页面自动续上原对话，不需要通知也能继续。

## FAQ

**Q：为什么不用"每 N 分钟的计划任务"来检查？**
进程周期性启动会产生 CPU/内存尖峰，落在游戏帧时间上就是掉帧；常驻进程平时完全静默，只在目标退出时行动。

**Q：杀掉服务后多久能恢复？**
看门狗检测到进程退出后立即重启，加上 120 秒冷启动容忍，通常 1~2 分钟内恢复；冷启动失败会退避重试（15s 起，上限 120s）。

**Q：重启时报 `EADDRINUSE` 怎么办？**
一般是双实例竞争端口。`Start-Web` 已加固：本实例失败但端口已被占用时视为成功，不会误报。
