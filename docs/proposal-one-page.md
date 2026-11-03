# Moon RateLimit 项目申报参考书（一页版）

## 确定性限流与弹性原语库

账号：yyqdbngt。GitHub：https://github.com/yyqdbngt/moon-ratelimit 。模块：123123213weqw/moon_ratelimit@0.2.0（发布于 123123213weqw 名下，仓库在 yyqdbngt）。MoonBit，Apache-2.0。

**空白与目标。** mooncakes 注册表 3472 个模块中无任何限流实现（rate-limit/bucket/throttle/GCRA 均检索为空）。本项目提供令牌桶、GCRA、固定/精确滑动窗口与种子化抖动退避，全部为注入时钟的纯决策函数。

**技术主菜。** GCRA 与令牌桶的按位等价律：不变式写在状态处，密集与 24 组伪随机日程上判定、retry_after 与余量逐位一致（二进有理参数下两浮点路径均精确，非二进的刀口边界如实记录）。固定窗口跨界 2× 缺陷以同日程对拍滑动窗口演示，不隐藏。

**验证。** 19 项测试声明 × 四后端零告警；8 夹具 + 4 锚定示例过真实 CLI；独立 Python oracle 57 项对拍（夹具、随机日程、逐位退避表）；统计机检（882/725 行）；一键 verify.sh 与 CI 复现。

**边界。** 单机内存、不协调、不读时钟；算法来源 ATM TM 4.x / AWS 2015 / Steele 2014 于 THIRD_PARTY.md 披露，主张为可验证实现而非算法首创。审核由主办方决定。
