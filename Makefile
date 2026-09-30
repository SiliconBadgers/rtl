.PHONY: setup doctor test
PYTHON ?= python3
setup:
	$(PYTHON) -c "import sys; assert sys.version_info >= (3, 11), 'Python 3.11+ required'; print('PASS setup: standard-library starter, no packages required')"
RTL_ROOT ?= .
MODELS_ROOT ?= ../software
CONTRACT ?= ../architecture/contracts/mac-v0.json
VERIFICATION_ROOT ?= ../verification
doctor: setup
	$(PYTHON) -c "import shutil; assert shutil.which('iverilog') and shutil.which('vvp'), 'Install Icarus Verilog'; print('PASS Icarus tools found')"
test:
	$(PYTHON) "$(MODELS_ROOT)/generate_vectors.py" --contract "$(CONTRACT)" --output build/mac-vectors.txt
	$(PYTHON) "$(VERIFICATION_ROOT)/run.py" --rtl-root "$(RTL_ROOT)" --vectors build/mac-vectors.txt

.PHONY: style format
style:
	$(PYTHON) scripts/check_style.py

format:
	$(PYTHON) scripts/check_style.py --fix
