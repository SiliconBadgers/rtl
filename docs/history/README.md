# Preserved development history

The combined RTL repository retains the original commits, branches, review
decisions and authorship for the control and memory work. These records preserve
the earlier reviews; they do not constitute new approvals. Links and repository
labels are normalized to the surviving locations. Comment and review IDs, authors,
timestamps, commit identities and technical content are retained.

[preserved-refs.json](preserved-refs.json) maps each source ref to its preserved
branch, tag or note ref in this repository. Original commit objects are unchanged.
The original Git AI notes are retained under `refs/notes/archive/control/ai` and
`refs/notes/archive/memory/ai` with their recorded model identities.
Historical AI setup discussions are not current contributor requirements; the
[current contribution guide](../../CONTRIBUTING.md) defines those requirements.

## Reviews

### Control

- [PR 1: Align team scaffolds and check AI setup before commits](control/pull-1.md)
- [PR 3: Expose exact model IDs in AI attribution](control/pull-3.md)
- [PR 4: Remove AI setup requirements for contributors](control/pull-4.md)
- [PR 5: Create top-level-control-architecture.md](control/pull-5.md)
- [PR 6: Add replaceable single-command RTL routing experiment](control/pull-6.md)
- [PR 7: Add independent SystemVerilog and Python style checks](control/pull-7.md)
- [PR 8: Direct new development to the combined RTL repository](control/pull-8.md)

### Memory

- [PR 1: Align team scaffolds and check AI setup before commits](memory/pull-1.md)
- [PR 3: Expose exact model IDs in AI attribution](memory/pull-3.md)
- [PR 4: Remove AI setup requirements for contributors](memory/pull-4.md)
- [PR 5: Point workspace setup to SoC](memory/pull-5.md)
- [PR 6: Direct new development to the combined RTL repository](memory/pull-6.md)

## Current work

- [Control assignment](https://github.com/SiliconBadgers/rtl/issues/6)
- [Memory assignment](https://github.com/SiliconBadgers/rtl/issues/7)
- [David Sklow’s pending proposal](https://github.com/SiliconBadgers/rtl/pull/10)
