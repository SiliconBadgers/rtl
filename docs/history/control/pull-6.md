# Control PR 6: Add replaceable single-command RTL routing experiment

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-30T05:14:14Z |
| Closed | 2026-10-02T09:40:55Z |
| Merged | No |
| Original head | [0d941a1ae8e2](https://github.com/SiliconBadgers/rtl/commit/0d941a1ae8e20928483579b2f406162ed2bc36c1) |
| Preserved branch | `archive/control/pulls/6/head` |

## Description

Moves command routing into Control as `command_router` with explicit endpoint ready/valid and completion ports. SoC owns the separate `command_router_test_top` and error-returning execution fixtures; the router no longer instantiates them. Uses SoC's `command_pkg`, named destinations, explicit update priority, and labeled ownership/stability assertions.

Formatting and style CI were split into and merged through SiliconBadgers/control#7. This PR now contains the RTL/test changes and related documentation only.

Validation: component style CI passes; eight routing cases and all 24 firmware service configurations pass in the coordinated SoC regression. Both CPU-backed ggml/Qwen probes also pass. Evidence: https://github.com/SiliconBadgers/soc/tree/feat/consolidated-integration/experiments/2026-09-30-sv-standards

This is a one-command routing experiment, not the full controller described by SiliconBadgers/rtl#6 or PR SiliconBadgers/control#5. Uses the package and fixture assembly in soc SiliconBadgers/control#6 with verification SiliconBadgers/control#7.

AI assistance: OpenAI Codex. The exact model identifier was unavailable in this execution context.


## Commits

- [23096da3ee82](https://github.com/SiliconBadgers/rtl/commit/23096da3ee8279cb231f6225ced39eda7ff1a38a): Add replaceable single-command routing experiment; author abhinavnandwani; 2026-09-30T05:01:16Z.
- [f1f13ad097bb](https://github.com/SiliconBadgers/rtl/commit/f1f13ad097bb22ba9a55bf509e295ee3f72208d4): Use SoC as the consolidated integration workspace; author abhinavnandwani; 2026-09-30T05:06:12Z.
- [8459cae5dbf5](https://github.com/SiliconBadgers/rtl/commit/8459cae5dbf5dd9db1cfcc60fe53bdb9e2715348): Apply SystemVerilog naming and enforced integration style checks; author abhinavnandwani; 2026-09-30T06:36:59Z.
- [be6873fa33c7](https://github.com/SiliconBadgers/rtl/commit/be6873fa33c719960161c27e6e6c22d473aa2c61): Keep integration RTL package ownership in SoC; author abhinavnandwani; 2026-09-30T15:19:02Z.
- [d1788cf99a6c](https://github.com/SiliconBadgers/rtl/commit/d1788cf99a6c42e463d59d7fa3047834fcf2aaa5): Use independent source-style tooling in the RTL branch; author abhinavnandwani; 2026-09-30T15:25:45Z.
- [3983fda73918](https://github.com/SiliconBadgers/rtl/commit/3983fda739183d769274248ec39826659f9057ff): Place RTL and test sources directly in their functional directories; author abhinavnandwani; 2026-09-30T15:26:59Z.
- [0d941a1ae8e2](https://github.com/SiliconBadgers/rtl/commit/0d941a1ae8e20928483579b2f406162ed2bc36c1): Merge remote-tracking branch 'origin/main' into feat/consolidated-integration; author abhinavnandwani; 2026-09-30T15:27:05Z.

## Review and discussion

### Comment 5949435338: abhinavnandwani

2026-10-02T09:40:54Z

Migrated with its original commits to https://github.com/SiliconBadgers/rtl/pull/9, now merged. SoC consumes the shared command package and router from the combined RTL repository. This former location is superseded.
