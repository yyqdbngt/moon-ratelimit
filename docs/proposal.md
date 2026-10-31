# Moon RateLimit 项目申报参考书

## 确定性限流与弹性原语库

账号：yyqdbngt；日期：2026 年 10 月 31 日；主要语言：MoonBit；许可：Apache-2.0。  
GitHub：https://github.com/yyqdbngt/moon-ratelimit  
公共模块：yyqdbngt/moon_ratelimit@0.1.0

本文供个人参考，按实际实现编写。公开提交与 CI 记录另附核对表，不以材料修订代替主办方复核。

## 一、项目目标与生态空白

给网关、任务队列和客户端重试提供可验证的准入决策原语：令牌桶、GCRA、固定窗口、精确滑动窗口与带抖动的指数退避。选此方向依据可复现查证：克隆 mooncakes.io 注册表索引（3472 个模块）检索 rate-limit / token bucket / throttle / GCRA，无一实现；retry 仅有单个 HTTP 特化包。限流是分布式系统的基础设施，而该生态位在 MoonBit 上为空。

## 二、已完成交付能力

| 能力 | 实际机制 | 输出及边界 |
|---|---|---|
| 令牌桶 | 容量与速率连续补充，时间由调用者注入 | 每事件判定与精确 retry_after；权重连续且不得超过容量 |
| GCRA | 理论到达时间状态，不变式 tokens = capacity − rate·max(0, tat−now) | 与令牌桶按位等价（见下）；同上边界 |
| 固定窗口 | 按墙钟窗口计数 | 拒绝时给出下一边界；跨界 2× 突发为已知且由测试演示 |
| 滑动窗口 | 记忆 (时刻, 权重)，半开区间 (now−window, now] | 精确拒绝并给出确切到期时刻；内存随窗口内事件数增长 |
| 退避与抖动 | 几何增长封顶 + none/full/equal/decorrelated 四形 | 种子化 SplitMix64，表逐位可复现；非密码学 |
| 使用入口 | MoonBit 库 execute/run 与 JSON CLI（stdin/文件） | 单 JSON 应答，错误信封与退出码 0/1/2 |

## 三、核心工程机制

时间注入而非读取：每个判定都是 (状态, now, 权重) 的纯函数，重放确定、跨四个后端一致，oracle 才可能对拍。

GCRA 与令牌桶的等价是本项目的技术主菜：状态即理论到达时间，不变式写在状态定义处；等价律按位断言——密集确定性日程与 24 组 LCG 伪随机日程（含同瞬突发）上，两种算法的判定、retry_after 与余量逐位一致。达成该严格度的前提被如实记录：参数取二进有理数（八分之一秒步长、四分之一令牌速率、整数容量）时两条浮点路径均精确；非二进速率在判决边界存在刀口翻转，属 double 的性质而非定理失效。过程中另记录两个被测试当场抓住的陷阱：LCG 种子未先取模导致 Int32 溢出并经 C 语义负余数污染全程；固定窗口跨界缺陷不隐藏而以同一日程对拍滑动窗口演示。

## 四、可复现案例

examples/windows.json：同一跨界日程，固定窗口放行 4 个、滑动窗口放行 2 个，输出逐字段锚定。examples/gcra.json 与 token-bucket.json：同一日程两种算法同判定。examples/backoff.json：种子 20261031 的抖动表逐位可复现。四个示例均由 CLI 实际执行并与钉死的期望输出比对。

## 五、验证与实际规模

19 项 MoonBit 测试声明（四后端全绿、--deny-warn 零告警）、8 个 CLI 夹具、4 个锚定示例；独立 Python oracle 复算 57 项检查：全部夹具、40 组随机二进有理日程跨四种算法、12 组种子×抖动的逐位退避表。生产代码 882 行（有效 725 行），由 scripts/stats.py 机检并写入 PROJECT_STATS.md。一键 sh scripts/verify.sh 与 CI（四后端矩阵 + 集成作业）复现全部证据。

## 六、使用与验收

库调用 execute(Json)/run(Value)；CLI `node _build/js/debug/build/cmd/main/main.js examples/token-bucket.json`。复核命令即 verify.sh 的展开清单，不另行维护第二套说辞。

## 七、当前边界与来源

单机内存决策库：不跨进程协调、不读时钟、不自行重试；分布式限流需共享存储，超出范围。浮点边界如第三节如实记录。窗口权重为整数。SplitMix64 非密码学。算法本身非首创（ATM 论坛 TM 4.x 的 GCRA、AWS 2015 抖动一文、Steele 的 SplitMix64），贡献在于 MoonBit 生态空白的可验证实现与证据链；来源详见 THIRD_PARTY.md。比赛准入与最终审核由主办方决定，公开发布不构成受理证明。
