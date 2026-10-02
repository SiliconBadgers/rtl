# Working in SiliconBadgers RTL

Read README.md, CONTRIBUTING.md, docs/START-HERE.md and the linked issue before
editing. Use a branch and PR for review. Keep the issue's technical scope intact.

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
