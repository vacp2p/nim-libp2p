# Logging policy

This is the authoritative guide for Chronicles log levels in nim-libp2p.
Severity represents operational impact and the action required from the library
user. It does not follow the wording of a message, whether code is in an
`except` branch, or whether an operation returned an error.

## Choose a level

1. Did an enabled component or background operation become unusable? Use
   `error`.
2. Is the library still operating, but the user should correct configuration,
   API use, a callback, or a resource constraint? Use `warn`.
3. Is this a low-frequency normal lifecycle milestone? Use `info`.
4. Is it a bounded summary of why an operation failed, was skipped, or selected
   a fallback? Use `debug`.
5. Is it an individual peer, message, stream, packet, retry, cancellation, or
   expected network event? Use `trace` or omit the log.

| Level | Audience and frequency | Meaning |
| --- | --- | --- |
| `error` | Operators; rare | An enabled component or background loop has stopped working and needs investigation. |
| `warn` | Library users; low frequency | The library remains usable, but a local configuration, API call, callback, or resource condition needs attention. |
| `info` | Operators; low frequency | A normal start, stop, or other lifecycle milestone. |
| `debug` | Developers troubleshooting one operation | A bounded result or fallback summary. |
| `trace` | Developers diagnosing traffic; potentially high frequency | Per-peer, per-message, per-stream, packet, retry, cancellation, and expected network detail. |

## Structured fields

Chronicle messages are stable, concise event descriptions. Put variable data in
structured fields rather than interpolating it into a message string.

| Field | Use |
| --- | --- |
| `err` | Human-readable exception or error-result text, normally `exc.msg`. |
| `errType` | Exception class, normally `exc.name`, only when it changes the diagnostic or operator response. |
| `peerId` | A local or remote peer identifier; add a separate direction or role field when needed. |
| `address` / `addresses` | One network or multiaddress value / a collection of them. |
| `protocol` | A negotiated or requested protocol identifier. |
| `operation` | A stable operation name when the event otherwise lacks context. |
| `attempt` / `maxAttempts` | Current and maximum retry counts. |
| `messageType` | Protocol message kind; never exception text. |
| `messageSize` | Encoded or payload size in bytes. |
| `reason` | A bounded validation, rejection, or decision reason when no exception or error result exists. |

Do not use `description`, `error`, `message`, or `msg` for exception text. Do
not log complete peer-controlled messages, buffers, records, advertisements,
keys, certificates, or tickets; log bounded metadata such as `messageType`,
`messageSize`, `peerId`, and `reason` instead.

## Network, exceptions, cancellation, and retries

Remote-controlled events must not produce `warn` or `error` merely because the
input is invalid. Malformed, incompatible, rejected, and adversarial peer input
is expected on a public P2P network; elevated logs would let peers create
production log noise. Log it at `trace`, or at `debug` only when a bounded
operation-level summary is useful.

An `except` block does not determine severity. Expected handled exceptions are
`trace` or unlogged. A recovered operation summary is `debug`; actionable
degradation is `warn`; and terminal component failure is `error`. When a failure
is returned or re-raised, reporting normally belongs to the caller, so do not
log it again at a higher level.

Normal cancellation is control flow: omit it or use `trace`. A real violation
of a cancellation contract can be `warn`. Individual retry failures are
`debug` or `trace`; emit one final `error` only when retry exhaustion leaves a
requested feature unavailable.

## Common cases

| Case | Level | Why; when to change it |
| --- | --- | --- |
| Malformed peer message | `trace` | Remote input is expected; use `debug` only for a bounded aggregate result. |
| Handshake or negotiation failure | `trace` | A peer/stream outcome; use `debug` for a final operation summary. |
| Dial or DNS attempt | `trace` | Per-address network flow; use `debug` after the whole requested operation fails. |
| Stream reset or timeout | `trace` | Expected per-stream network outcome; use `debug` for a bounded result. |
| Lifecycle start or stop | `info` | Normal, low-frequency milestone. |
| Repeated lifecycle call | `warn` | The caller can correct the API use. |
| Invalid local configuration | `warn` | The user can correct configuration; use `error` only if an enabled component cannot run. |
| Application callback exception | `warn` | The library survives, but application code needs attention. |
| Rejected caller-supplied publish operation | `warn` | The caller can reduce message size or correct inputs. |
| Resource limit or degraded optional feature | `warn` | User attention may restore desired behaviour; use `trace` for a per-peer enforcement event. |
| Fallback selection | `debug` | A bounded explanation of the selected path. |
| Background-loop termination | `error` | The enabled operation is no longer working. |
| Internal invariant violation | `error` | It indicates a library defect requiring investigation; use `debug` if recovered locally. |
