.PHONY: setup doctor test
UV ?= uv
PYTHON ?= python3
RUN_PYTHON = "$(UV)" run --locked "$(PYTHON)"
export UV PYTHON
setup:
	"$(UV)" sync --locked
RTL_ROOT ?= .
doctor: setup
	$(RUN_PYTHON) scripts/vcs.py check
test: test-matrix-unit

.PHONY: style format
style:
	"$(UV)" run --locked --group dev "$(PYTHON)" scripts/check_style.py

format:
	"$(UV)" run --locked --group dev "$(PYTHON)" scripts/check_style.py --fix

# Matrix-unit systolic array regression (tb/compute/Matrix_Unit/run_tests.sh).
# Pass runner options through MATRIX_UNIT_ARGS, e.g. MATRIX_UNIT_ARGS="--seeds 7".
.PHONY: test-matrix-unit
MATRIX_UNIT_ARGS ?=
test-matrix-unit:
	bash tb/compute/Matrix_Unit/run_tests.sh $(MATRIX_UNIT_ARGS)

.PHONY: test-tooling
test-tooling:
	$(RUN_PYTHON) -m unittest discover -s scripts -p 'test_*.py'
