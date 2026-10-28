# Command queues and shared scoreboard

This document proposes the command-queue and scoreboard interfaces and behavior.
Implementation and verification are separate work.

The proposed `command_queues` contains one FIFO each for Memory, Matrix, and
Vector, connected to a shared set of milestone counters. Its parent supplies an opaque payload and
two dependency targets per enqueue. Each head issues when its dependencies pass
and the unit accepts it.

## Configuration and dependencies

The wrapper parameters are `QueueDepth=4`, `PayloadWidth=32`, and
`CounterWidth=16`. All are positive integers. The processor integration selects
its payload and counter widths to match firmware and the connected units.

| FIFO | Target 0 | Target 1 |
| --- | --- | --- |
| Memory | Matrix progress | Vector progress |
| Matrix | Memory progress | Vector progress |
| Vector | Memory progress | Matrix progress |

Each unit supplies a two-bit increment per clock: `00`, `01`, and `10` advance
its counter by zero, one, and two milestones. `11` and unknown values fail a
simulation assertion; hardware holds that counter for an illegal encoding.
The counters wrap modulo `2^CounterWidth`. Publishers retain excess events and
supply increments exactly once in command order. The interface accepts up to
two milestones per unit per cycle.

A target of zero disables its comparison. For other targets, subtract the target
from progress at `CounterWidth` bits; a clear top bit means reached or passed.
Software keeps live distances strictly below half the counter range. The exact
half-range difference is unsatisfied. Comparisons use registered progress, so
an increment accepted at an edge first affects issue eligibility in the following
cycle.

## Queue behavior

`QueueDepth` counts accepted, unissued commands. Entries issue in FIFO order.
The FIFO supports depth one and non-power-of-two depths. A newly enqueued entry
first becomes eligible in the following cycle.

Nonempty, nonfull FIFOs support simultaneous enqueue and issue. A full FIFO
accepts a replacement on the cycle after an issue frees space. This keeps
push-ready independent of unit-ready; depth-one acceptance is consequently
limited to every other cycle.

Once an issue has been offered, its valid, payload, and targets remain stable
until acceptance or reset, including when progress subsequently wraps. Empty
FIFOs drive payload and targets to zero. Unit-ready determines execution capacity.

`command_queue` stores one FIFO's payload and targets and retains offered heads.
`shared_scoreboard` stores all three counters and evaluates the six comparisons.
`command_queues` connects those blocks. The head-target-to-issue-valid path is
combinational; the unit interface must preserve an acyclic handshake path.

## Clock and reset

All ports share rising-edge `clk_i`. The parent synchronizes deassertion of
asynchronous active-low `rst_ni`. Reset clears FIFO occupancy, pointers, retained
offers, and progress. Payload arrays retain their contents, invalidated by empty
occupancy. Push-ready and issue-valid are low during reset.

The parent coordinates reset with issued work and prevents stale milestone
pulses from entering the new epoch. Queued records are cancelled by reset.
Verification must check FIFO ordering, dependency gating, retained offers, wrap,
increments, and active reset.
