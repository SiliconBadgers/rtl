# Working in SiliconBadgers RTL

Read [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md),
[docs/START-HERE.md](docs/START-HERE.md), and the linked issue before editing.
Before changing SystemVerilog, read the [coding standard](docs/systemverilog-style.md).
Use a branch and PR for review. Keep the issue's technical scope intact.

Compute1 and Compute2 independently investigate the full compute-unit design
in research/compute1 and research/compute2. Do not split their operation coverage
or combine recommendations by default. Control and memory retain their own
responsibilities under docs/control and docs/memory.

Link shared architectural material instead of duplicating it. Distinguish
accepted interfaces, proposals, assumptions, real RTL and stubs. Preserve dated
experiments and record new results separately with reproduction details.

Do not commit secrets, licensed collateral, model weights or generated databases.
Run proportionate checks and report their scope accurately. Preserve authorship
and licensing. Report the exact AI model ID in the PR when available; do not guess.

## Pull requests and verification

- Every PR must link a GitHub issue in its description. Use `Closes #123` only
  for completed issue scope and `Refs #123` for partial work. Create a scoped
  issue first if there is no suitable issue. Do not close broad issues for a
  partial implementation.
- Follow the PR template and the evidence requirements in CONTRIBUTING.md.
  A Notion task or chat message does not substitute for the GitHub issue.
- Changes to RTL or verification collateral must report actual verification
  statistics in the PR: tested commit, configuration, seeds, tests run/passed/
  failed/skipped, relevant checked transactions or vectors, and elapsed time.
  Define counts; never invent results or coverage.
- Include or update a checked-in regression script or Make target. Give exact
  fresh-checkout commands, prerequisites, tool versions, dependency revisions,
  and result paths. Preserve failure exit codes and enforce a timeout.
- Link the run summary and logs. Report unrun checks and limitations explicitly.
  After code changes, rerun affected checks and refresh the PR evidence.
  Documentation-only PRs must explain why hardware regression is not applicable
  and list the checks actually performed.
- Run `make format` when needed and `make style` before submitting SV/Python
  changes. Style checks are not a substitute for functional verification.

`CLAUDE.md` is a relative symlink to this file. Keep one set of agent instructions.
