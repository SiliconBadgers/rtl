# Control PR 3: Expose exact model IDs in AI attribution

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-23T03:04:10Z |
| Closed | 2026-09-23T03:05:52Z |
| Merged | 2026-09-23T03:05:52Z |
| Original head | [453a20a08b5a](https://github.com/SiliconBadgers/rtl/commit/453a20a08b5a5fab97de269e0c03ff28e0b487e2) |
| Preserved branch | `archive/control/pulls/3/head` |

## Description

Model identity was stored in Git AI notes but the contribution workflow exposed only a generic agent credit. Add a Model attribution check that renders captured tool/model IDs alongside each commit's AI-Model declarations in the GitHub job summary. Update agent/contributor instructions and the PR template to disclose every exact reported model ID, its role, switches/subagents, and unavailable IDs.

The report supports v2/v3 note metadata, excludes prompts/session IDs/emails, and visibly identifies missing metadata. It cannot infer hidden model routing, detect undisclosed use, or measure per-PR model line totals. The existing pre-commit setup guard and branch protections are unchanged.

Validation: 21 contributor tests pass, including 8 report tests for multiple models, missing/malformed metadata, trailer parsing, disclosure conflicts, normal merges and escaping. Shared report/test/workflow files match across all ten repos. The report was also checked against real existing notes and this contribution's captured note.

| Tool | Exact reported model ID | Used for | Evidence |
|---|---|---|---|
| codex | gpt-6-astra | Implementation, documentation and validation | Current session metadata and this commit's Git AI note |

AI-Model trailers and Codex co-author credit are present. The explicit checkpoint uses an empty transcript; no conversation text is supplied. No model-identity gaps are known for this change.


## Commits

- [453a20a08b5a](https://github.com/SiliconBadgers/rtl/commit/453a20a08b5a5fab97de269e0c03ff28e0b487e2): Expose exact AI model IDs in commit and PR attribution; author abhinavnandwani; 2026-09-23T03:04:05Z.

## Review and discussion

No comments or submitted reviews were recorded.
