# URPC

## Basics

URPC is for local programs calling local services.

Client API:

```ruby
client.call(:search, q: "text")
stream = client.stream(:watch_key, key)
```

The transport is filesystem-based:

```text
client prepares an inline or file-backed request
client writes a submit frame to the service submit FIFO
server reads the submit frame
server writes the result to the client output FIFO
```

Each service key owns one directory under `/tmp/urpc2`.
One server process owns that key while it is running.
The server reads submitted frames and decides how to run the calls.
Service keys must match `[0-9a-z_]+`.

Clients need a transport that works from restricted local environments.
Files and FIFOs in `/tmp` work reliably there.
Sockets are blocked.

Each service key is a directory like this:

```text
/tmp/urpc2/<key>/
  server.lock
  submit.fifo
  calls/
  output/
  input/
```

`submit.fifo` is a stable rendezvous point.
Clients and servers create it if it is missing.
Normal server start and stop should leave it in place.

`server.lock` protects service ownership.
The server keeps an exclusive `flock` while it owns the service key.
Only one process should read `submit.fifo` for a key.

Client wait behavior follows FIFO open behavior.
The client acquires the submit FIFO write fd before creating per-call paths, then writes the submit frame to that already-open fd after the per-call paths are ready.

- `wait_for_server: false`: open `submit.fifo` for writing with `NONBLOCK`; `ENOENT` or `ENXIO` means no server is ready
- `wait_for_server: true`: ensure `submit.fifo` exists, then use blocking open and wait for a server reader
- `wait_for_server: N`: retry nonblocking open until the deadline

`wait_for_server` and call timeout protect different phases.
`wait_for_server` is only the rendezvous budget: how long the caller is willing to wait for a service process to exist.
Call timeout is the execution budget: how long the caller is willing to wait after submission for a terminal response.
A service may legitimately take a long time to process a request, but if the service does not exist, callers usually want to fail fast instead of spending that whole execution budget waiting on nothing.

Client-visible transport failures collapse to two cases:

- no-server: no server reader became available during `wait_for_server`, or submit open/write failed before the server owned the call
- call-timeout: the call was submitted, but no terminal output frame was delivered before the call deadline

Every submit frame has an id.
For inline casts the id is unused after submission.
File-backed request bodies live in `calls/<id>.msgpack`.
The server writes non-cast responses to `output/<id>.fifo`.
Bidirectional calls also use `input/<id>.fifo` for client-to-server messages.

## Assumptions

- OS: Linux, current Arch Linux. No portability or backwards compatibility target.
- Runtime directory: one shared local `/tmp`.
- `PIPE_BUF = 4096`.
- FIFO writes of `<= PIPE_BUF` bytes are atomic.
- Clients and servers are trusted local processes.
- Runtime state is disposable.
- Submit FIFO writers are protocol-compliant. Truncated or hand-written partial submit frames are out of scope.
- `submit.fifo` filling up is out of scope.

## Wire

Stream FIFOs carry byte-tagged frames:

```text
tag      u8
payload  MessagePack value, only when the tag requires one
```

For payload-bearing tags, payload is always present even when the logical value is `nil`.
For no-payload tags, no MessagePack object follows the tag byte.

### Submit frame

`submit.fifo` carries fixed-header submit frames.
The server reads one header, then reads one payload if the header says an inline payload is present.

Header:

```text
flags        u8
call_id      8 bytes
payload_len  u16
```

`call_id` is binary on the wire and lowercase hex in filenames.
For example, the 8 wire bytes become `calls/<16 hex chars>.msgpack` and `output/<16 hex chars>.fifo`.

Flags:

```text
INLINE        0x01
CAST          0x02
BIDIRECTIONAL 0x04
```

If `INLINE` is set, `payload_len` is the byte length of the payload immediately following the header.
If `INLINE` is not set, `payload_len` must be zero and the request payload lives in `calls/<id>.msgpack`.

The request payload is MessagePack:

```ruby
[method_name_string, args, kargs]
```

Submit frames must fit in one atomic FIFO write.
For inline submits, `header.bytesize + payload_len` must stay under the chosen `PIPE_BUF` budget.
For file-backed submits, only the fixed header is written to `submit.fifo`.

### Output frames

`output/<id>.fifo` carries response frames from the server to the client.

| Tag | Name | Payload | Meaning |
|---|---|---|---|
| `0x01` | `DATA` | MessagePack value | Non-terminal stream event. |
| `0x02` | `RETURN` | MessagePack value | Terminal success result. |
| `0x03` | `ERROR` | MessagePack `error_hash` | Terminal failure result. |
| `0x04` | `INPUT_READY` | none | Bidirectional input setup. |

`error_hash` is a MessagePack hash:

```ruby
{
  exception: "ArgumentError",
  message: "bad input",
  backtrace: [...]
}
```

A non-cast output stream ends with exactly one terminal frame.

### Input frames

`input/<id>.fifo` carries input frames from the client to the server for bidirectional calls.

| Tag | Name | Payload | Meaning |
|---|---|---|---|
| `0x11` | `READY` | none | Client input writer is attached. |
| `0x12` | `SYNC` | MessagePack value | Synchronous input payload. |
| `0x13` | `ASYNC` | MessagePack value | Asynchronous input payload. |

The server opens `input/<id>.fifo` for reading.
Once its input reader is ready, the server writes `INPUT_READY` to `output/<id>.fifo`.
The client then opens `input/<id>.fifo` for writing, unlinks the path, and writes `READY`.

`SYNC` and `ASYNC` frames are invalid before `READY`.
EOF before `READY` means the client attached and died.
EOF after `READY` means the client-side input stream disconnected.

### MessagePack

All MessagePack payloads use the project default MessagePack factory.

## FIFO rules

These are the operational rules the flows depend on.
The Linux FIFO behavior behind them is in the appendix.

### Ordering

The client acquires a submit writer before creating per-call artifacts:

1. open `submit.fifo` for writing according to `wait_for_server`
2. write `calls/<id>.msgpack` (file-backed payloads only)
3. `mkfifo` `output/<id>.fifo`, and `input/<id>.fifo` for bidirectional calls
4. open `output/<id>.fifo` for reading with `NONBLOCK` (succeeds instantly)
5. write the submit frame to the already-open submit fd

Because the client's read end is open before the submit frame exists, the server can never lose a race to it.
The server's write open of `output/<id>.fifo` is a single `NONBLOCK` attempt: success, or `ENXIO`/`ENOENT` meaning the client died, in which case the server drops the call and removes the leftover per-id paths.

Per-call FIFO readers are opened with `NONBLOCK` and read only after poll readiness.
No side ever blocks in open for a per-call FIFO, so no open needs a deadline or a retry loop.
All client waiting is poll waiting (`wait_readable` bounded by the call timeout), which is trivially interruptible.

### Atomic writes, stream reads

Every submit frame is written with one `write` call.
The whole frame must fit in 4076 bytes: `PIPE_BUF` (4096 on Linux) minus a 20-byte defensive margin.
With the 11-byte header, inline `payload_len` is at most 4065.
Writes up to `PIPE_BUF` are atomic, so concurrent clients cannot interleave frames and a short write is impossible; treat one as a fatal bug.

The submit write itself never blocks: open with `NONBLOCK`, `wait_writable` with a 5-second deadline (the pipe can be full under burst), then one `write`.
Open/write failure or writable-deadline expiry surfaces as no-server to the caller.

Read boundaries do not align with write boundaries.
The server parses `submit.fifo` as a byte stream: buffered read, fixed header, then `payload_len` bytes.

`output` and `input` FIFOs have exactly one writer each, so their frames need no size limit and no atomicity care; both sides stream-parse byte tags and MessagePack payloads.

### Unlink discipline

Per-call paths exist only to rendezvous; the fds are the call.

- `calls/<id>.msgpack`: the server unlinks it immediately after reading it, before dispatch.
- `output/<id>.fifo`: the server unlinks it right after its write open succeeds.
- `input/<id>.fifo`: the client unlinks it right after its write open succeeds.

If submission fails, the client removes everything it created.
If the server drops a call before rendezvous completes, it removes the per-id paths.

Call ids are 8 random bytes; collisions are treated as a non-problem.
`/tmp` hygiene: payload files are created with `CREAT | EXCL`, and each side verifies an opened per-call path is actually a FIFO (`stat.pipe?`) before using it.

### The input handoff

The bidirectional `input` FIFO bootstraps in a fixed order.

1. The server opens `input/<id>.fifo` for reading with `NONBLOCK`.
2. The server writes `INPUT_READY` to `output` — the first frame of every bidirectional call, before dispatch.
3. The client sees `INPUT_READY`, opens `input` for writing with `NONBLOCK` (the server's read end already exists, so this succeeds; `ENXIO` means the server died), unlinks the path, and writes `READY`.
4. The server's poll-gated input reader wakes for the first time on `READY`; the server then dispatches the handler.

The server bounds step 4 with a 1-second deadline: the round trip is normally sub-millisecond, and a client that saw `INPUT_READY` answers `READY` immediately.
`SYNC` and `ASYNC` frames before `READY` are protocol errors.

## Flows

### Cast

```text
client                                     server
------                                     ------
pack [method, args, kargs]
open submit.fifo for write                 (read end already open via O_RDWR)
if too big for inline:
  write calls/<id>.msgpack
write submit frame (CAST [| INLINE])
close, return nil
                                           read frame
                                           if file-backed: read + unlink calls/<id>.msgpack
                                           dispatch; errors are logged, never reported
```

A fresh id is always generated; for inline casts it is unused.
If the submit open fails (`ENOENT`, `ENXIO`, or deadline), the client unlinks the payload file if it wrote one, and the cast is silently dropped.
No FIFOs are created; the delivery guarantee is only that the frame reached the server's pipe buffer.

### Call

```text
client                                     server
------                                     ------
pack [method, args, kargs]
open submit.fifo for write
if too big for inline:
  write calls/<id>.msgpack
mkfifo output/<id>.fifo
open output r NONBLOCK
write submit frame ([INLINE])
wait for frames (poll + timeout)           read frame; read + unlink payload
                                           open output w NONBLOCK
                                             (ENXIO/ENOENT: client died -> drop + clean)
                                           unlink output/<id>.fifo
                                           dispatch handler
read frames                                write DATA ...
                                           write one terminal RETURN / ERROR
done; close read fd                        close output fd
```

Submit failure: the client unlinks the output FIFO and payload file, then raises no-server.
After successful submit, failure to receive a terminal frame before the call deadline raises call-timeout.
Client timeout closes the read fd; the server's next output write raises `EPIPE` and it abandons the call.
A plain call and a streaming call are the same flow; streaming just means the client yields `DATA` frames as they arrive instead of expecting zero of them.

### Bidirectional

```text
client                                     server
------                                     ------
pack [method, args, kargs]
open submit.fifo for write
if too big for inline:
  write calls/<id>.msgpack
mkfifo output/<id>.fifo
mkfifo input/<id>.fifo
open output r NONBLOCK
write submit frame (BIDIRECTIONAL)
wait for frames (poll + timeout)           read frame; read + unlink payload
                                           open output w NONBLOCK; unlink output path
                                           open input r NONBLOCK
                                           write INPUT_READY
read INPUT_READY
open input w NONBLOCK
unlink input/<id>.fifo
write READY
                                           read READY (1s deadline)
                                           dispatch handler
write SYNC/ASYNC ...                       read input frames (poll-gated)
read output frames                         write DATA ...
                                           write terminal frame; close fds
close input write fd
```

`INPUT_READY` is the first frame on `output` for a bidirectional call, written before dispatch, so the client's frame loop can treat it as a fixed prologue.
The client may close its input write end early; that is a valid half-close (server sees EOF on input), and the server still owes a terminal frame on `output`.
If the server dies before `INPUT_READY`, the client sees call-timeout.
The meanings of `SYNC` vs `ASYNC` input frames are handler-level semantics, defined separately from the transport.

## Ruby API

```ruby
client = Urpc::Client.new("service_key", timeout: 30, wait_for_server: false)
client.call(:search, q: "text")        # -> terminal return value
client.stream(:watch_key, "name")      # -> Urpc::EventStream
client.cast(:log, "event")             # -> nil
client.bidirectional_stream(:chat)     # -> Urpc::EventStream
```

`timeout:` is the call execution timeout.
`timeout: 0` means no call timeout.

`wait_for_server:` is the submit rendezvous budget.
`false` fails immediately when no server is ready, `true` waits indefinitely for a server reader, and a numeric value waits up to that many seconds.

Blocks are not accepted across RPC boundaries.
Arguments are positional plus keyword arguments; the request payload is `[method_name_string, args, kargs]`.

`EventStream` exposes:

- `next_event` -> next `DATA` event or raises/finishes on terminal frames
- `each_event { |event| ... }`
- `result` -> terminal return value
- `close`
- `finished?`

`Client` multiplexes streams:

- `next_event(*streams)` -> `[stream, event]`
- `each_event(*streams) { |stream, event| ... }`

Bidirectional streams also expose:

- `await_input`
- `input_open?`
- `send_sync(value)`
- `send_async(value)`
- `close_input`

## Appendix: Linux FIFO semantics

- `open(..., WRONLY | NONBLOCK)` fails with `ENXIO` when no reader is open.
  This is the submit liveness probe.
- `open(..., RDONLY | NONBLOCK)` succeeds immediately, so read-open cannot detect a writer.
- Blocking open returns when the other direction opens.
  The only intentional blocking open is `wait_for_server: true` on `submit.fifo`.
- `read` with no writers returns EOF immediately, even if no writer ever attached.
  This is vacancy EOF.
- `poll` does not report a FIFO read end as ready until a writer has attached since that read end was opened.
  After a writer attaches and detaches, poll reports hung up EOF persistently.
- Read per-call FIFOs only after poll readiness.
  That avoids vacancy EOF; EOF then means a real peer disconnect.
- `submit.fifo` is long-lived, so the server keeps its own write end open (`O_RDWR`, or read fd plus second write fd) to suppress EOF for its whole run.
- For bidirectional input, the server opens `input/<id>.fifo` for reading before the client opens it for writing.
  Until the client writer attaches, that read end does not poll as ready.
  EOF before `READY` means the client attached and died; EOF after `READY` means the client closed its input side.
