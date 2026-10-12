# Contributing

Read [the current assignments](docs/START-HERE.md) and the relevant team charter.
Create a branch from `main` and propose changes through a pull request. Main
requires one code-owner approval. Record ownership in the linked issue.

Put compute, control and memory sources in `rtl/compute/`, `rtl/control/` and
`rtl/memory/`. Shared block packages belong in `rtl/common/`. SoC composition and
CPU/host wrappers remain in the SoC repository. Keep Compute1 and Compute2's
complete research proposals independent.

Run `make style` and checks appropriate to the changed behavior. Record source
revisions, commands, tool versions and results for experiments. Preserve dated
evidence; publish new runs alongside it. Label stubs and proposals accurately.

Do not commit secrets, licenses, PDKs, model weights or generated simulation
and build databases. Preserve source licensing and authorship. If an AI agent
assists, identify the tool and exact model ID when available in the PR
summary; state when the model ID is unavailable rather than guessing.

## Coding standard

Follow the [SystemVerilog coding standard](docs/systemverilog-style.md) for
project-authored RTL and testbenches. Tool installation and the `make format`
and `make style` commands are documented in [SETUP.md](SETUP.md#source-style).
Verible checks formatting and selected lint rules; reviewers must also check the
standard's interface, reset, parameter, and verification requirements.

## Link issues to pull requests

Every PR must link at least one GitHub issue in its description and explain the
scope it delivers. Create a scoped issue first if none exists. Use:

- `Closes #123` when merging the PR completes the issue's acceptance criteria.
- `Refs #123` when the PR delivers only part of the work; describe what remains.
- A full GitHub issue URL for another repository, with the same completion or
  partial-work distinction.

A Notion task may provide context but does not replace the GitHub issue. Use the
[PR template](.github/pull_request_template.md) and keep its evidence current as
the branch changes. Do not leave template prompts in a submitted PR.

## Verification results in the PR

PRs changing RTL, testbenches, assertions, reference models, test vectors, or
regression tooling must include a verification summary in the PR description:

- Tested commit, tool versions, dependency revisions, configurations, and seeds.
- Tests planned, run, passed, failed, and skipped; relevant checked transactions
  or vectors; elapsed time. Define what each count measures. A case does not
  count as multiple tested paths unless each path was exercised.
- Coverage type, scope, exclusions, and results when measured. Otherwise write
  "Not measured"; do not infer coverage from a passing simulation.
- Links to a run summary and detailed logs as CI artifacts or a small committed
  report. Keep generated build databases and large waveforms out of Git. Record
  artifact expiry when applicable and keep enough metadata to reproduce the run.
- Failures, unrun checks, limitations, and any code changes made after the run.
  Rerun affected checks after fixes and update the tested commit and results.

A screenshot, a bare PASS, or an unsupported claim of exhaustive testing is not
sufficient. Separate simulation, formal, synthesis, timing, and CDC/reset results.
Documentation-only changes may use "Not applicable" for hardware regression,
with a reason and the documentation checks actually performed.

## Reproduce the regression

Verification contributions must include or update a checked-in regression script
or Make target and link it in the PR. The runner belongs with its block tests or
in the repository's existing test tooling. Extend an existing runner when it
covers the change; do not create a separate runner for each PR.

Provide copyable commands from a fresh checkout, including:

1. Checkout of the tested commit and any pinned external dependencies.
2. Required tools, exact versions, and setup or installation instructions.
3. Working directory, full regression command, configurations, and random seeds.
4. Expected result summary and the paths to generated logs and reports.

The runner must return nonzero on compilation errors, failed checks, missing
required tests, or timeout. Bound simulation time, propagate subprocess failures,
and preserve exit codes when capturing logs (for example, use `pipefail` when
piping a simulator through `tee` in Bash). A testbench that only prints FAIL and
then finishes successfully is not a passing regression. Report the actual test
counts and failures, and allow a failing seed/configuration to be rerun.

Do not depend on undocumented local files, personal absolute paths, or manually
entered simulator commands. A reviewer should be able to run the checked-in
entry point without reconstructing the author's workstation.

## Maintain the coding standard

The repository and [Notion edition](https://app.notion.com/p/3eb38826be1b81129170e99b72affdca)
must carry the same version and coding rules. Propose coding-rule changes in a PR,
then update the Notion edition when that change merges. Keep repository workflow
rules here and in the PR template; do not add them to the Notion coding standard.
