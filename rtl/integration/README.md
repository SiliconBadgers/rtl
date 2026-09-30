# Command routing experiment

`sb_accelerator_top` is a single-command routing stub, not a complete device top
or the controller proposed in PR #5. It owns a command until its completion is
consumed, blocks acceptance during quiesce and rejects unknown opcodes/ABIs.
It does not fetch descriptors, issue memory transfers or drain real writes.

Shared types come from Architecture. The `sb_engine_stub` instances are supplied
by the consolidated SoC workspace as integration fixtures; they are
not Compute or Memory implementations. Every supported test route returns
`UNIMPLEMENTED`. The memory route is a simulation test route, not a compute unit.

Run `./scripts/workspace.sh test` from the SoC checkout. Its pinned
Verification submodule supplies the testbench. As real controller RTL arrives,
replace this experiment through a reviewed interface change rather than copying
its implementation into the system workspace.
