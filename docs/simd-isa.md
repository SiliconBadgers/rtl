# Silicon Badgers 32-bit SIMD ISA

Each SIMD instruction occupies **32 bits, stored as four little-endian bytes**.
The [signature catalogue](simd-isa-signatures.md) lists all 135 legal operations,
their operand roles and types, and their fixed behavior.

**Source: [SIMD Commands Google Sheet](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit).**
See the [Commands](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit#gid=0),
[Flags](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit#gid=1), and
[Signatures](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit#gid=2) tabs.

## Command word

| Field | Bits | Width | Meaning |
| --- | --- | --- | --- |
| `FAMILY` | 31:29 | 3 | Operation group |
| `SIG` | 28:22 | 7 | Fixed operation and type combination within `FAMILY` |
| `D` | 21:18 | 4 | Result register or predicate, as declared by the signature |
| `A` | 17:13 | 5 | First input or signature-specific role |
| `B` | 12:8 | 5 | Second input, shift count, exponent, divisor, lane index, or predicate |
| `C` | 7:3 | 5 | Addend, shift count, choice predicate, or remainder output; otherwise zero |
| `PM` | 2:0 | 3 | Execution predicate; `CONTROL` requires zero |

Unused operand fields must be zero.

## Families and fixed signatures

| `FAMILY` | Group | Signatures | Selection |
| --- | --- | --- | --- |
| `000` | `CONTROL` | 3 | `SETVL=0`, `PAND=1`, `PNOT=2` |
| `001` | `ALU` | 56 | `function_index × 8 + type_index` |
| `010` | `PRODUCT` | 9 | Listed `PRODUCT` IDs |
| `011` | `REDUCE` | 18 | Listed `REDUCE` IDs |
| `100` | `CAST` | 24 | `source_type_index × 8 + destination_type_index` |
| `101` | `SPECIAL` | 18 | Listed `SPECIAL` IDs |
| `110` | `DATA` | 7 | Listed `DATA` IDs |
| `111` | Invalid | 0 | Reject |

The `ALU` type indices are `0 F16, 1 F32, 2 I32, 3 U32, 4 I64, 5 U64`.
The function indices are `ADD=0`, `SUB=1`, `EQ=2`, `LT=3`, `SELECT=4`, `AND=5`,
`XOR=6`, `SHL=7`, `SHR=8`, `CLZ=9`, `ADD_SAT=10`, `SUB_SAT=11`, and
`RSHIFT_RNE=12`.

`CAST` uses this type order:
`0 F16, 1 F32, 2 I8, 3 U8, 4 I16, 5 U16, 6 I32, 7 I64`.
Bit `6` of a `CAST` signature is zero. These are its legal conversion pairs:

| Source | Destinations |
| --- | --- |
| `F16` | `F16`, `F32`, `I32`, `I64` |
| `F32` | `F16`, `F32`, `I32`, `I64` |
| `I8` | `I32` |
| `U8` | `I32` |
| `I16` | `I32` |
| `U16` | `I32` |
| `I32` | `F16`, `F32`, `I8`, `U8`, `I16`, `U16`, `I32`, `I64` |
| `I64` | `F16`, `F32`, `I32`, `I64` |

`U32` and `U64` are storage and arithmetic types. `CAST` supports only the pairs
listed above.

## Registers, constants, and operand roles

`V0`–`V7` are vector registers, with one value per physical lane. `S0`–`S7` are
scalar registers, each holding one value shared by all lanes. Register cells
hold 64 bits. `P0`–`P7` hold one boolean predicate bit per lane. `P0` is
permanently true; only `P1`–`P7` are writable.

| Numeric reference code | Operand |
| --- | --- |
| `0`–`7` | `V0`–`V7` |
| `8`–`15` | `S0`–`S7` |
| `16` | Zero |
| `17` | Floating negative zero |
| `18` | One |
| `19` | Integer all-ones |
| `20`–`31` | Invalid |

## Execution and state

`VL` is the active vector length, from zero through the physical lane count.
For a non-control instruction, lane `i` executes exactly when:

```text
i < VL and P[PM][i] is true
```

Disabled lanes perform no calculation, access, numeric error check, counter
update, or write. `PM=P0` enables every lane below `VL`. `SELECT` uses predicate
`C` to choose between `A` and `B`, independently of `PM`.

An ordinary scalar result requires all numeric sources to be scalar or constant.
Scalar `SELECT` reads `C` at the lowest enabled lane.
`REDUCE` always writes a scalar result, using positive floating zero or integer
zero for an empty enabled set. `DIVMOD` requires distinct `D` and `C` outputs,
both scalar or both vector; `C` is an output rather than a source.

`SETVL` reads a `U32` scalar or constant from `A`, validates it against the
physical lane count, and updates `VL` even when its previous value was zero.
`PAND` and `PNOT` update predicate bits below `VL`, retain higher bits, and
require `PM=0`. Comparisons update only the lanes enabled by `VL` and `PM`.

Inputs and outputs can share registers, subject to the signature's restrictions; `DIVMOD` outputs
must be distinct. `PERMUTE` captures its vector input before writing, so in-place
rearrangement is valid. Its enabled indices must be below the physical lane
count. The selected source lane can be outside `VL` or masked off.

The issuer selects stored command words, repeats sequences, and coordinates
SIMD and matrix work. It owns registers, predicates, `VL`, execution mode, and
diagnostics until dependent compute and memory work completes. Memory logic moves
values between memory and registers and fetches lookup-table entries.

## Numeric behavior and faults

Floating numeric operations require finite enabled inputs and finite results.
They round to nearest, with halfway ties choosing an even result, and retain
subnormals. `FMA` forms the exact product plus addend and rounds once. Mixed
`FMA` reads `F16` values from `A` and `B`, reads `F32` from `C`, and writes `F32`
to `D`. Floating division rounds the exact quotient once. For multiplication
alone, use negative-zero constant `C=17` with `FMA` and integer-zero constant
`C=16` with `WMAC`. The catalogue defines each operation's domain restrictions.

Integer `ADD`, `SUB`, and checked products reject an exact result outside the
destination type's range. `WMAC` checks the exact product-plus-addend result
after addition. Raw shifts and bitwise logic follow their bit-pattern rules. `MULSHIFT` permits
`0`–`63`; rounded right shift permits counts at or above its input width.

`CAST` reads an `I32` exponent `e` in `−255…255` and converts the exact value
`A × 2^e` with one rounding. Float-to-float requires `e=0`. Integer destinations
clamp to their range and record conversion saturation; floating overflow faults.
Convert directly to the destination rather than through an intermediate float.

`MULSHIFT` clamps its rounded product to `I32`.
A compute sequence uses one execution mode: strict or permissive. Permissive
mode commits clamped results; strict mode records saturation and faults without
writing the failing instruction's outputs. Ordinary overflow and domain errors
fault in both modes.

`REDUCE.SUM` includes every physical lane, in lane-index order, pairing adjacent
positions and then adjacent partial sums. Lanes at or above `VL` and lanes with
a false `PM` predicate contribute zero. Convert `F16` leaves exactly to `F32` and round each
floating tree addition to `F32`. `MIN` and `MAX` ignore disabled lanes and
keep the lowest enabled lane's value on ties, including its floating zero sign.
Every empty reduction writes positive zero or integer zero.

## Programs and lookup tables

`ABS`, `NEG`, `MIN`, `MAX`, `OR`, `ARGMAX`, packed `I4` operations, quantization,
and workload recipes are programs composed from primitive commands. The
[Lowerings tab](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit#gid=4)
records example behavior and scratch-register requirements. They are not
additional `FAMILY`/`SIG` pairs. `ARGMAX` returns `index=0` and `valid_count=0`
for an empty set. Preserve the independent execution mask and temporary-register
lifetimes when lowering a program.

SIMD programs calculate lookup-table indices and interpolate values supplied
through the register interface.
The [Contracts tab](https://docs.google.com/spreadsheets/d/1XtrQoqvEHGf_vmuHE5VzVlQ5l0E2RK3TIvoId99a1Kk/edit#gid=3)
records these execution rules and the reference table recipes.

See the [Control guide](control/START-HERE.md) and
[command-routing pilot](control/command-router.md) for controller interfaces.
