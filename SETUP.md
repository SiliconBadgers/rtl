# RTL setup

Reading design material requires no EDA tools. The runnable MAC example requires
Make, Python 3.11+ and Icarus Verilog (`iverilog`, `vvp`). Use the pinned
[SoC workspace](https://github.com/SiliconBadgers/soc) for combined checks.

With Architecture, Software and Verification checked out as siblings:

```sh
make setup
make doctor
make test MODELS_ROOT=../software CONTRACT=../architecture/contracts/mac-v0.json VERIFICATION_ROOT=../verification
```

The Verification runner must support the `rtl/compute/pe_mac.sv` location.
The example checks arithmetic and pipeline behavior only.

## Source style

Install Verible v0.0-3946-g851d3ff4 and Ruff 0.16.6, and put their executables on
PATH. CI pins those versions and checks only tracked project sources.

```sh
make style
make format
```

Verible formats and lints SystemVerilog. Ruff formats and lints Python tooling.
Generated build products, external dependencies and licensed collateral do not
belong in Git.
