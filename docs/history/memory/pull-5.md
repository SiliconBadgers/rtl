# Memory PR 5: Point workspace setup to SoC

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-30T05:14:31Z |
| Closed | 2026-10-02T09:40:58Z |
| Merged | No |
| Original head | [8dc4d819ea78](https://github.com/SiliconBadgers/rtl/commit/8dc4d819ea7815f2570a0d89289a9826c9f1165c) |
| Preserved branch | `archive/memory/pulls/5/head` |

## Description

Updates the shared workspace setup link after consolidation into SoC. No memory RTL or interface changes. Validation: the destination setup guide is included in the linked SoC consolidation PR.

AI assistance: OpenAI Codex. The exact model identifier was unavailable in this execution context.


Related consolidation PRs:
- architecture: https://github.com/SiliconBadgers/architecture/pull/10
- control: https://github.com/SiliconBadgers/rtl/blob/main/docs/history/control/pull-6.md
- software: https://github.com/SiliconBadgers/software/pull/8
- verification: https://github.com/SiliconBadgers/verification/pull/7
- rtl-compute: https://github.com/SiliconBadgers/rtl-compute/pull/5
- memory: https://github.com/SiliconBadgers/rtl/blob/main/docs/history/memory/pull-5.md
- physical-design: https://github.com/SiliconBadgers/physical-design/pull/6
- planning: https://github.com/SiliconBadgers/planning/pull/4
- soc: https://github.com/SiliconBadgers/soc/pull/6

Merge component changes first, then update SoC gitlinks to their resulting merged commits before merging the SoC workspace.


## Commits

- [8dc4d819ea78](https://github.com/SiliconBadgers/rtl/commit/8dc4d819ea7815f2570a0d89289a9826c9f1165c): Point workspace setup to consolidated SoC repository; author abhinavnandwani; 2026-09-30T05:09:34Z.

## Review and discussion

### Comment 5949436077: abhinavnandwani

2026-10-02T09:40:57Z

Superseded by the merged repository consolidation in https://github.com/SiliconBadgers/rtl/pull/8 and the SoC workspace in https://github.com/SiliconBadgers/soc/pull/6. The active memory guide is https://github.com/SiliconBadgers/rtl/blob/main/docs/memory/START-HERE.md.
