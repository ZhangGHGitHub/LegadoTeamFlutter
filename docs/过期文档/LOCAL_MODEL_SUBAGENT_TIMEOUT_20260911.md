# 本地子代理超时根因排查：ninfer-serve 准入（admission）与共享 KV 池

**日期**：2026-09-11　**排查人**：Qoder（主代理）
**现象**：给 `full-stack-engineer` 子代理（模型 `custom:0c7859bc…:qwen3.8-27b-nvfp4full`，指向本地 `http://127.0.0.1:8080`）并行派发两个任务时，其中一个报 `inference request expired while waiting for admission` 失败（已两次：C1、A4）。用户实测「并行两个子代理可同步运行」，故需定位差异原因。

## 一、结论（根因）

**服务端准入策略拒绝/搁置 + 单实例 KV 池偏小**：`ninfer-serve` 对每个请求按其 **预留量（prompt + 输出预算）** 向**全实例共享的 KV 池**申请容量；两个子代理都是「大上下文请求」（反复整读 600–2000 行源码），二者预留之和超过 `--kv-capacity 131072` 时，后到请求只能排队等待；而当前实例**未设 pending 超时**（用默认值），等待超时即被丢弃，返回的正是该错误。

> 与「后端只能串行」无关（我上一轮的猜测有误）：实例本身是 `--max-concurrency 2`，并发能力存在；瓶颈是**共享 KV 容量**，不是槽位数。

## 二、证据链

1. **错误来源是服务端**：ZCode 日志 `v2/logs/2026-09-11.log` / `cli/log/zcode-2026-09-11.jsonl` 中
   `error.cause.context.responseBodySummary.error.message = "inference request expired while waiting for admission"`、`error.type = timeout_error` —— `responseBodySummary` 表明这串文本来自应答体，即服务端返回，非客户端排队。
2. **运行实例参数**（`Get-CimInstance Win32_Process` 取 CommandLine，进程启动 2026-09-11 18:50:45）：
   ```
   ninfer-serve.exe models\qwen3_8_27b_nvfp4full.ninfer --host 127.0.0.1 --port 8080
     --max-context 131072 --kv-capacity 131072 --max-concurrency 2 --kv-dtype nvfp4
     --spec mtp --draft-tokens 3 --lm-head-draft --vision
     --default-max-tokens 32768 --default-thinking-budget 4096
   ```
   - `--kv-capacity 131072`：**全实例共享** KV 池 = 13.1 万 token；
   - `--default-max-tokens 32768` + `--default-thinking-budget 4096`：每个请求按最多 ~36.8k 输出预留；
   - **无 `--max-pending-requests` / `--pending-timeout-ms`**（默认值生效）。
   - 注：目录里的 `serve-qwen38-nvfp4full.bat` 写的是 `65536 / int8`，与在线实例不一致 —— 该实例是**另按手改命令行启动**的，改参数需重启。
3. **准入判定文本**（`ninfer-serve.exe` 二进制内可读字符串）：
   `admission_policy`、`request reservation exceeds Engine shared KV capacity`、`admission did not reserve thinking-control token capacity`、`pending request capacity and timeout must be nonzero`、`--pending-timeout-ms`。
   → 预留超出共享 KV 即为准入受阻；pending 队列有容量与超时两个参数。
4. **ninfer 官方 launcher 的取值对比**：`qwen3_8_27b_nvfp4full.bat` 等均显式给 `--max-pending-requests 50 --pending-timeout-ms 3000000`（50 分钟），说明**默认 pending 超时远小于 50 分钟**；在线实例没给这两个参数。
5. **两侧现象自洽**：
   - 用户实测并行可行 → 测试请求上下文小，两条预留之和 < 131k，均能准入；
   - 我方子代理单发（C3、A3）成功、并发（C1、A4 之一）失败 → 单条大请求能进（prompt ≲ 95k），两条和超池；
   - 失败耗时 ≈ 393s / 512s（约 6.5–8.5 分钟）与「等一段默认 pending 超时后被丢弃」吻合。

## 三、可选处置（按代价从低到高）

| 方案 | 操作 | 代价 / 风险 |
|---|---|---|
| A. 子代理串行派发（主代理侧，**已采用**） | 前一子代理回报后再派下一个 | 零服务端改动；吞吐减半 |
| B. 收窄子代理上下文（派发侧） | 任务书要求：大文件用 offset/limit 分段读、只回传结论、避免整文件转储 | 降单请求预留，提高并发成功率 |
| C. 重启实例补 pending 参数 | 启动行加 `--max-pending-requests 50 --pending-timeout-ms 3000000` | 排队不再被丢弃；但池满时仍要等到前序结束（表现为慢，不再报错） |
| D. 重启实例扩 KV 池 | `--kv-capacity auto`（留 1GiB 余量）或显式 `196608/208000`，配合 `--kv-dtype k8v4/int8` 省显存 | 24GB 卡显存受限，需实测；或降 `--default-max-tokens`（32768→16384/8192）减小单请求预留 |

## 四、操作口径（已同步记忆）

- 在服务端未按 C/D 调整前，主代理派发子代理**按串行执行**（也满足「最多并行 2 个」上限）；
- 任务书统一加入「大文件分段读、减少上下文膨胀」的要求；
- 若需真并行，请先按 C（+D）重启本地服务，再并行派发。

编写者：Qoder（主代理）｜ 2026-09-11
