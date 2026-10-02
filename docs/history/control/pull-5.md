# Control PR 5: Create top-level-control-architecture.md

| Record | Value |
|---|---|
| Author | [David-Sklow](https://github.com/David-Sklow) |
| Created | 2026-09-26T03:35:31Z |
| Closed | 2026-10-02T09:40:53Z |
| Merged | No |
| Original head | [931f81f7284a](https://github.com/SiliconBadgers/rtl/commit/931f81f7284a48b197730bdca3c326e4e9a17ca1) |
| Preserved branch | `archive/control/pulls/5/head` |

## Description

Start to constructing the expanded block level diagram for the top level controller (by help of claude)

## Change

Linked issue and what this contribution delivers:

## Evidence

Commands, source/tool revisions and observed results. State unrun checks,
remaining assumptions and any stub-only results.


## Commits

- [931f81f7284a](https://github.com/SiliconBadgers/rtl/commit/931f81f7284a48b197730bdca3c326e4e9a17ca1): Create top-level-control-architecture.md; author David Sklow; 2026-09-26T03:34:55Z.

## Review and discussion

### Review 5357858614: abhinavnandwani

2026-09-29T20:13:25Z; CHANGES_REQUESTED

This is a useful controller proposal. The separation between the command sequencer, transfer controller, and engine-local controllers is a good starting point. I am requesting two corrections before it merges as a proposal.

1. The block diagram routes `Error Handler → Completion / IRQ Post`, but §§2 and 6 say a mid-command error must first drain accepted transfers and writeback. Please make the diagram and prose agree. An invalid descriptor can report immediately if no work was accepted; a fault with accepted work needs the defined drain path.
2. Please define what “Host” means at this boundary: the application machine, device-side firmware, or simply the software/firmware command submitter. CPU placement is still an architecture choice, so this document should not silently settle it.

I have opened [architecture PR #6](https://github.com/SiliconBadgers/architecture/pull/6) to make the shared boundaries and the CPU-placement alternative reviewable. The detailed register/descriptor contract remains [architecture #3](https://github.com/SiliconBadgers/architecture/issues/3); I am not asking you to finalize it in this PR. Our broader technical report was not available in the repo when this proposal was written, so I am not treating its unpublished details as requirements you missed.


### Comment 5898045846: abhinavnandwani

2026-09-29T20:20:33Z

Correction to my review after checking the September 27 and 28 meeting records: the working system design **retains an on-device RISC-V core**. What remains open is how command decomposition and sequencing are split between the application host and that firmware, plus the exact interface. The current shared diagram predates that direction; I am correcting it in architecture PR #6 and updating architecture #7.

My request here is still to name the command submitter and keep the accelerator controller distinct from the CPU. I am not asking this PR to implement or choose the RISC-V core. Sorry for describing CPU placement itself as undecided in the review.


### Comment 5949434705: abhinavnandwani

2026-10-02T09:40:52Z

Development continues in https://github.com/SiliconBadgers/rtl/pull/10 after consolidation into the RTL repository. David Sklow’s original commit 931f81f7284a48b197730bdca3c326e4e9a17ca1 is retained unchanged as an ancestor. This PR and its review history remain available here. The migrated PR is still a draft: the error-drain diagram and command-submitter definition remain unresolved. Closing this superseded location does not accept the proposal.
