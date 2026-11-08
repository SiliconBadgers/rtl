# Control

Read [the current assignment](START-HERE.md), [charter](CHARTER.md) and [objectives](OBJECTIVES.md).
Sources live in `rtl/control/` at the repository root.

The [top-level control unit specification](top_level_control_spec.md) defines
the Ibex subsystem, PeakRDL registers, host interface, and command submission.

The [command queues and shared scoreboard proposal](command-queues.md) defines
FIFO ordering, dependency counters, issue handshakes, and reset behavior.
