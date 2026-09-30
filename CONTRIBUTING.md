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
