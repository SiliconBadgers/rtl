.PHONY: setup doctor test
PYTHON ?= python3
setup:
	$(PYTHON) -c "import sys; assert sys.version_info >= (3, 11), 'Python 3.11+ required'; print('PASS setup: standard-library starter, no packages required')"
RTL_ROOT ?= .
doctor: setup
	$(PYTHON) scripts/vcs.py check
test: test-matrix-unit

.PHONY: style format
style:
	$(PYTHON) scripts/check_style.py

format:
	$(PYTHON) scripts/check_style.py --fix

# Matrix-unit systolic array regression (tb/compute/Matrix_Unit/run_tests.sh).
# Pass runner options through MATRIX_UNIT_ARGS, e.g. MATRIX_UNIT_ARGS="--seeds 7".
.PHONY: test-matrix-unit
MATRIX_UNIT_ARGS ?=
test-matrix-unit:
	bash tb/compute/Matrix_Unit/run_tests.sh $(MATRIX_UNIT_ARGS)
