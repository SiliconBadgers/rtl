# `<block>` specification

Copy to `<block>/doc/<block>.md`. Rules: `guides/spec-style-guide.md`.

| | |
|---|---|
| RTL | `<path>` @ `<commit>` |
| Design owner | `<name>` |
| Verification owner | `<name>` |
| Version | `<1.0>` |

## 1. Summary

`<What the block does.>`

## 2. Block diagram

`<Diagram and a short description.>`

## 3. Parameters

| Parameter | Default | Valid range | Description |
|---|---|---|---|
| `<NAME>` | | | |

Out-of-range values: `<...>`

## 4. Clocks and resets

| Signal | Description |
|---|---|
| `<CLK>` | |
| `<nRST>` | |

## 5. Ports

| Port | Dir | Width | Reset value | Description |
|---|---|---|---|---|
| `<port>` | | | | |

Protocol rules:

- P1. `<...>`

## 6. Register map

| Offset | Register | Access | Reset | Description |
|---|---|---|---|---|
| `0x00` | `<REG>` | | | |

| Bits | Field | Access | Reset | Software | Hardware |
|---|---|---|---|---|---|
| | | | | | |

## 7. Functional description

### 7.1 Programming model

1. `<...>`

### 7.2 Operation

`<...>`

### 7.3 Timing

| Operation | Latency | Throughput |
|---|---|---|
| | | |

| Cycle | `<inputs>` | `<outputs>` |
|---|---|---|
| 0 | | |

## 8. Requirements

| ID | Requirement |
|---|---|
| R01 | `<The block shall ...>` |

## 9. Corner cases

| Condition | Behaviour | Req |
|---|---|---|
| | | |

## 10. Assumptions

| ID | Assumption |
|---|---|
| AS1 | |

## 11. Known limitations

| ID | Limitation |
|---|---|
| L1 | |

## 12. Open questions

| ID | Question | Owner | Answer |
|---|---|---|---|
| Q1 | | | |

## 13. Revision history

| Version | Date | RTL commit | Change |
|---|---|---|---|
| 1.0 | | | |
