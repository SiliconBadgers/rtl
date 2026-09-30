# Command routing experiment

`command_router` is a single-command routing stub, not a complete device top
or the controller proposed in PR #5. It owns a command until its completion is
consumed, blocks acceptance during quiesce and rejects unknown opcodes/ABIs.
It does not fetch descriptors, issue memory transfers or drain real writes.

Shared RTL types come from SoC’s `rtl/integration/command_pkg.sv`. The `engine_stub` instances are supplied
by the consolidated SoC workspace as integration fixtures; they are
not Compute or Memory implementations. Every supported test route returns
`UNIMPLEMENTED`. The memory route is a simulation test route, not a compute unit.

Run `./scripts/workspace.sh test` from the SoC checkout. Its pinned
Verification submodule supplies the testbench. As real controller RTL arrives,
replace this experiment through a reviewed interface change rather than copying
its implementation into the system workspace.

The router exposes per-destination ready/valid channels and completion inputs.
SoC owns `command_router_test_top` and its error-returning endpoint fixtures.
The parent broadcasts the command payload while the selected request is valid;
endpoints sample it on their ready/valid handshake and retain accepted fields
for their own execution lifetime. The shared clock and reset apply to every
endpoint. Reset clears router ownership; the parent must reset the fixtures too.
