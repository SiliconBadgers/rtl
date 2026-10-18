# Standalone MAC retirement: tooling evidence

Scope: retire the obsolete standalone MAC and its dependent test entry points.
The supported test command selects the existing RTL-owned Matrix Unit suite.
This is not equivalent coverage of the retired accumulator and is not new
independent verification coverage.

## Locally executed checks

- Python 3.12.14, standard-library unittest; no random seeds (deterministic).
- `python3 -m unittest discover -s scripts -p 'test_test_entrypoint.py'`:
  2 planned, 2 run, 2 passed, 0 failed, 0 skipped.
- Python syntax compilation passed for the new test file.
- Test scope: Make/source dependency contracts only; fake Make targets are not
  a simulator or evidence about hardware arithmetic.
- No current Matrix RTL, testbench or regression-script content is changed.
- Functional/code coverage: not measured. Hardware simulations: 0 run.
- VCS Y-2026.03_Full64 and local Verible/Ruff are unavailable. Licensed
  simulation and full local style checks were not run. CI style results must
  be checked on the published commit separately.

## Reproduce

Run the unittest command above from this repository root. For hardware,
use the pinned licensed VCS environment and `make test`; see SETUP.md.
Record both repository revisions, actual configurations, counts and logs.
Historical MAC reports remain evidence for their original revisions only.

Related cleanup: SiliconBadgers/rtl#21; partial scaffold work tracked by
https://github.com/SiliconBadgers/verification/issues/4.
Assisted by OpenAI Codex; exact model ID unavailable.
