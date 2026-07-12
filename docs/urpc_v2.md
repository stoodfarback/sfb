# URPC

## Basics

URPC is for local programs calling local services.
Clients need a transport that works from restricted local environments, where sockets are blocked but files and FIFOs in `/tmp` work reliably.

Client API:

```ruby
client.call(:search, q: "text")
stream = client.stream(:watch_key, "name")
```

The transport is filesystem-based:

```text
client prepares an inline or file-backed request
client writes a submit frame to the service submit FIFO
server reads the submit frame
server writes the result to the client output FIFO
```

Each service key owns one directory under `/tmp/urpc2`:

```text
/tmp/urpc2/<key>/
  server.lock
  submit.fifo
  calls/
  output/
  input/
```

Service keys must match `[0-9a-z_]+`.
One server process owns a key while it is running.
The server reads submitted frames and decides how to run the calls.

`submit.fifo` is a stable rendezvous point.
Servers and clients configured to wait for a server create it if it is missing.
Fail-fast clients do not create it.
Normal server start and stop should leave it in place.

`server.lock` protects service ownership.
The server keeps an exclusive `flock` while it owns the service key.
Only one process should read `submit.fifo` for a key.

Client wait behavior follows FIFO open behavior.
`wait_for_server` controls how the client opens `submit.fifo` for writing:

- `wait_for_server: false`: open `submit.fifo` for writing with `NONBLOCK`; `ENOENT` or `ENXIO` means no server is ready
- `wait_for_server: true`: ensure `submit.fifo` exists, then use blocking open and wait for a server reader
- `wait_for_server: 0`: behave exactly like `false`
- `wait_for_server: N`: for a finite positive numeric value, ensure `submit.fifo` exists and retry nonblocking open until the deadline

`wait_for_server` and call timeout protect different phases.
`wait_for_server` is only the rendezvous budget: how long the caller is willing to wait for a service process to exist.
Call timeout is the execution budget: how long the caller is willing to wait after submission for a terminal response.
A service may legitimately take a long time to process a request, but if the service does not exist, callers usually want to fail fast instead of spending that whole execution budget waiting on nothing.

Client-visible transport failures collapse to three cases:

- no-server: no server reader became available during `wait_for_server`, or submit open/write failed before the server owned the call
- server-disconnected: after attaching to the call, the server closed its output without a terminal response or disappeared during bidirectional input attachment
- call-timeout: the call was submitted, but no terminal output frame was delivered before the call deadline

Every submit frame has an id.
File-backed request bodies live in `calls/<id>.msgpack`.
The server writes non-cast responses to `output/<id>.fifo`.
Bidirectional calls also use `input/<id>.fifo` for client-to-server messages.
For inline casts the id is unused after submission.

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
The server handles a submit in two steps: acceptance and hydration.
Acceptance reads one frame off the FIFO: the fixed header, plus the inline payload when the header says one is present.
It preserves FIFO frame boundaries without unpacking the request or reading a file-backed payload.
Hydration parses the request payload and, for file-backed requests, reads and unlinks `calls/<id>.msgpack`.
The simple in-process server accepts and immediately hydrates; process fanout forwards accepted bytes and hydrates in a worker.

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
| `0x03` | `ERROR` | MessagePack error tuple | Terminal failure result. |
| `0x04` | `INPUT_READY` | none | Bidirectional input setup. |

The error payload is a fixed MessagePack tuple of exception name, message, and backtrace:

```ruby
[
  "ArgumentError",
  "bad input",
  [...],
]
```

The tuple must contain exactly three fields: two strings followed by an array of strings.

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

Because the client's read end is open before the submit frame exists, the server's write open cannot lose a race to a client that is still setting up.
The write open of `output/<id>.fifo` is a single `NONBLOCK` attempt: success, or `ENXIO`/`ENOENT` meaning the client died, in which case the server drops the call and removes the leftover per-id paths.

Per-call FIFO readers are opened with `NONBLOCK` and read only after poll readiness.
No side ever blocks in open for a per-call FIFO, so no open needs a deadline or a retry loop.
All client waiting is poll waiting (`wait_readable` bounded by the call timeout), which is trivially interruptible.

### Atomic writes, stream reads

Every submit frame is written with one `write` call.
The whole frame must fit in 4076 bytes: `PIPE_BUF` (4096 on Linux) minus a 20-byte defensive margin.
With the 11-byte header, inline `payload_len` is at most 4065.
Writes up to `PIPE_BUF` are atomic, so concurrent clients cannot interleave frames and a short write is impossible; if one happens anyway, it is a fatal bug.

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

Cleanup is best-effort while the participating processes are alive.
Abrupt client or server death may leave payload files or FIFOs behind.
URPC does not sweep stale artifacts or clean them during server startup; random call ids make leftovers operationally harmless, and the entire runtime root is disposable `/tmp` state that may be removed when no services or calls are using it.

Call ids are 8 random bytes; collisions are treated as a non-problem.
`/tmp` hygiene: payload files are created with `CREAT | EXCL`, and each side verifies an opened per-call path is actually a FIFO (`stat.pipe?`) before using it.

### The input handoff

The bidirectional `input` FIFO bootstraps in a fixed order.

1. The server opens `input/<id>.fifo` for reading with `NONBLOCK`.
2. The server writes `INPUT_READY` to `output` — the first frame of every bidirectional call, before dispatch.
3. The client sees `INPUT_READY`, opens `input` for writing with `NONBLOCK` (the server's read end already exists, so this succeeds; `ENOENT`, `ENXIO`, or `EPIPE` raises `Urpc::ServerDisconnected`), unlinks the path, and writes `READY`.
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
After successful submit, reaching the call deadline without a terminal frame raises call-timeout.
If the server attached to the output FIFO and closes it before a terminal frame, the client immediately raises server-disconnected instead of waiting for the deadline.
Client timeout closes the read fd.
The server translates `EPIPE` from its next response write into an internal client-disconnected signal and silently abandons that call.
An `EPIPE` raised by application code is unrelated and still escapes the handler normally.
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
If the server dies before attaching to the output FIFO, the client sees call-timeout.
If it dies after attaching but before `INPUT_READY`, the client sees server-disconnected immediately.
The meanings of `SYNC` vs `ASYNC` input frames are handler-level semantics, defined separately from the transport.

## Ruby API

### Client

```ruby
client = Urpc::Client.new("service_key", timeout: 0, wait_for_server: false)

client.search(q: "text")              # method_missing -> call
client.call(:search, q: "text")       # -> terminal return value
client.stream(:watch_key, "name")     # -> Urpc::Stream
client.cast(:log, "event")            # -> nil
client.bidirectional(:chat)           # -> Urpc::Bidirectional
```

`timeout:` is the call execution timeout.
It must be a real, finite numeric value greater than or equal to zero.
The default is `0`, which means no call timeout.

`wait_for_server:` is the submit rendezvous budget.
It must be `false`, `true`, or a real, finite numeric value greater than or equal to zero.
`false` and numeric zero fail immediately when no server is ready, `true` waits indefinitely for a server reader, and a positive numeric value waits up to that many seconds.

Blocks are not accepted across RPC boundaries.
Method names must not be empty.

`Stream` includes `Enumerable`.
Iteration yields `DATA` payloads, including `nil`.
`RETURN` ends iteration and stores the terminal value for `result`; `ERROR` raises the remote exception.

`Stream` exposes:

- `each { |data| ... }` -> yields `DATA` payloads; without a block, returns an `Enumerator`
- `result` -> terminal return value
- `close`
- `finished?`

Bidirectional streams expose:

- `await_input`
- `input_open?`
- `send_sync(value)`
- `send_async(value)`
- `close_input`

Client-visible failures:

- `Urpc::TransportError` is the common base for client-visible RPC transport and call-lifecycle failures.
- `Urpc::NoServerError` when no server reader becomes available during `wait_for_server`, or submit fails before the server owns the call.
- `Urpc::TimeoutException` when a submitted call does not deliver a terminal frame before `timeout`.
- `Urpc::ServerDisconnected` when the attached server closes output before a terminal response, or disappears during bidirectional input attachment after `INPUT_READY`.
- Handler exceptions are re-raised on the client with the original class when loadable, otherwise `Urpc::RemoteException`.

`NoServerError`, `TimeoutException`, and `ServerDisconnected` inherit from `TransportError`.
`RemoteException` does not: it represents a remote application exception, not a transport failure.

### Server

A server owns one service key and receives each submitted request as a `Urpc::Req`.
`client.call` and `client.stream` differ only on the client side: a call drains the output stream and returns the terminal value, while a stream exposes `DATA` payloads.
Server code handles both through the same `Urpc::Req` API.

```ruby
Urpc::Server.new("service_key") do |req|
  case req.name
  when :search
    rows = search(*req.args, **req.kargs)
    req.finish(rows)
  when :watch_key
    key = req.args.fetch(0)
    req.data("#{key}:one")
    req.data("#{key}:two")
    req.finish("done")
  else
    raise(ArgumentError, "unknown urpc method: #{req.name}")
  end
end.run
```

The block interface is deliberately low-level.
The server passes `req` to the block, ignores the block's return value, and does not inspect or close the request after the block returns.
The request may outlive the block when another thread retains it.
A non-cast request remains open until its owner calls `req.finish`, `req.error`, or `req.close`.
Returning without finishing or retaining the request is a handler bug; the client eventually observes call-timeout while the output remains open, or server-disconnected when it closes.

The server does not convert exceptions raised by the block into error responses.
With the default inline executor they propagate out of `Server#run`; other executor failure behavior is described under "Server execution."
The internal client-disconnected signal from a response write is the exception: every request execution boundary catches it and abandons only that request.
Automatic return handling, exception conversion, and cast exception logging belong to the higher-level dispatch interfaces.

Every request starts unfinished, including casts.
Casts use the same request lifecycle but have no response stream: `req.data` skips the output write, while `req.finish` and `req.error` skip the output write and mark the request finished normally.
Handlers usually do not need to branch on `req.cast?`.

`Urpc::Req` exposes:

- `name` -> requested method name as a symbol; the Ruby layer converts the wire method-name string to a symbol
- `args` -> positional arguments
- `kargs` -> keyword arguments
- `cast?`
- `bidirectional?`
- `data(value)` -> send a non-terminal `DATA` frame
- `finish(value = nil)` -> send a terminal `RETURN` frame
- `error(exception)` -> send a terminal `ERROR` frame
- `finish_if_open(value = nil)` -> atomically send `RETURN` if unfinished; return whether it was sent
- `error_if_open(exception)` -> atomically send `ERROR` if unfinished; return whether it was sent
- `finished?`
- `close` -> close the request without a terminal frame
- `next_input` -> next tagged input frame for a bidirectional request

`next_input` is the raw block-mode input interface.
It returns a `Urpc::StreamFrame::Frame` whose type is `:sync` or `:async`, and raises `EOFError` when the client input side disconnects.
The higher-level bidirectional dispatch interface separates synchronous input from asynchronous callbacks.

### Class dispatch

`Urpc::Dispatch` maps request names to endpoints or proc-convertible inline handlers.

```ruby
dispatch = Urpc::Dispatch.new(
  search: Search,
  watch_key: WatchKey,
  ping: -> { :pong },
  chat: Chat,
)

Urpc::Server.new("service_key", &dispatch).run
```

Dispatch works by evaluating `endpoint.handle(req)`.
Endpoints are duck-typed: any object that responds to `handle` is stored directly.
Mappings that do not respond to `handle` must respond to `to_proc`.
They are normalized during construction into anonymous `Urpc::Handler` subclasses using `define_method(:call, &endpoint)`.
Their return values and exceptions therefore use the same lifecycle as explicit handler classes.
Use an explicit handler class when the implementation needs streaming helpers, bidirectional input, or per-request initialization.
It converts `StandardError` exceptions from handler construction, invocation, and unknown methods to `req.error`.
Exceptions from casts or after terminal completion are logged because they cannot be returned to the client.
Broken output pipes close the request and are not reported as handler errors.
Exceptions outside `StandardError`, including `NotImplementedError`, deliberately escape dispatch.
URPC's request and input-reader threads use `abort_on_exception`, so an exception that escapes one of those threads is re-raised in the main thread and normally terminates the server process.

`Urpc::Handler` is the base class for ordinary request handlers:

```ruby
class Search < Urpc::Handler
  def call(q, limit: 10)
    index.search(q).first(limit)
  end
end
```

`Urpc::Handler#initialize(req)` stores `req`.
Subclasses that override `initialize` must call `super(req)`.

`Urpc::Handler.handle(req)` constructs the handler and runs it.
`Urpc::Handler#run` calls `call(*args, **kargs)`.
If `call` returns before the request is finished, the return value is sent with `finish`.
Exception handling belongs to `Urpc::Dispatch`.
The default `call` raises `NotImplementedError`.

`Urpc::Handler` exposes:

- `req`
- `data(value)`
- `finish(value = nil)`
- `error(exception)`
- `finished?`

`Urpc::BidirectionalHandler` extends `Urpc::Handler` for bidirectional request handlers:

```ruby
class Chat < Urpc::BidirectionalHandler
  def call(room:)
    data(status: "joined", room:)

    loop do
      message = receive
      data(message:)
    end
  rescue EOFError
    "disconnected"
  end

  def receive_async(value)
    close_input if value == :cancel
  end
end
```

`Urpc::BidirectionalHandler#initialize(req)` calls `super(req)`, verifies that `req.bidirectional?`, and creates its input helper.
The transport-level input handoff has already completed before request dispatch.
Subclasses that override `initialize` must call `super(req)`.

`Urpc::BidirectionalHandler#run` starts a dedicated input-reader thread before invoking `call`, then closes the input helper when the handler finishes.
The reader thread queues `SYNC` payloads for `receive`, invokes `receive_async(value)` for `ASYNC` payloads, and invokes `on_disconnect` when the client closes its input side.
This lets asynchronous input reach a handler while its main call thread is doing other work.
The synchronous input queue is intentionally unbounded.
The reader must continue past queued `SYNC` frames so a later `ASYNC` frame can reach the handler immediately; applying queue backpressure would block that cancellation/control path behind synchronous work.
URPC services and clients are trusted local peers, so preserving asynchronous control-message liveness is preferred over imposing a fixed backlog limit.

`Urpc::BidirectionalHandler` exposes the `Urpc::Handler` helpers plus:

- `input`
- `receive`
- `receive_async(value)`
- `disconnected?`
- `close_input`
- `on_disconnect`

`receive` returns the next synchronous input payload.
The default `receive_async(value)` raises `NotImplementedError` when an asynchronous input frame is received.
The default `on_disconnect` does nothing.

### CLI commands

`Urpc::CliCommand` is the base class for server-owned commands invoked by `urpc-call-cli`.
Map each command class through `Urpc::Dispatch` like any other handler:

```ruby
class Verify < Urpc::CliCommand
  def help_text
    "Usage: verify\n"
  end

  def perform!
    paths = glob("inbox/*.yml")
    stdout("found #{paths.size}\n")
    0
  end
end

Urpc::Server.new("service_key", &Urpc::Dispatch.new(verify: Verify)).run
```

`Urpc::CliCommand.handle(req)` creates one `Urpc::CliSession` for the RPC request.
The session extends `Urpc::BidirectionalHandler` and owns the request, bidirectional input reader, caller-side operations, output, and cancellation state.
The command is a plain object that owns only the logical command lifecycle.

The client submits no positional arguments and exactly two keyword fields:

```ruby
client.bidirectional(
  :verify,
  argv: [...],
  caller_cwd: "/caller/working/directory",
)
```

`argv` must be an array of strings and `caller_cwd` must be a non-empty string.
Both are exposed to commands, and `command_name` is the requested RPC method name.

The command lifecycle calls `set_defaults!`, recognizes a lone `-h` or `--help`, then calls `parse_argv!` and `validate!` before invoking `execute!`.
`execute!` delegates to `perform!` by default and is the extension point for application-level execution wrappers.
`set_defaults!`, `parse_argv!`, and `validate!` default to no-ops; subclasses must implement `perform!`.
Help writes `help_text` to stdout and returns status 0.
An `OptionParser::ParseError` or `ArgumentError` raised by `parse_argv!` or `validate!` writes the error and help text to stderr and returns status 2.
Those exceptions are not converted when raised by `set_defaults!`, `help_text`, `execute!`, `perform!`, output helpers, or caller operations; failures outside argument parsing are command failures and reach the client as remote errors.
`perform!` returns an integer exit status from 0 through 255; `nil` means 0.
The terminal value is that integer status directly.

Logical subcommands use the same command class and share the existing session:

```ruby
class Main < Urpc::CliCommand
  def perform!
    name, *command_argv = argv
    command_class = COMMANDS.fetch(name)
    run_subcommand(command_class, command_name: "tool #{name}", argv: command_argv)
  end
end
```

`run_subcommand` accepts a command class, an explicit `command_name:`, an `argv:`, and optional application constructor keywords.
It constructs the child with the current session and runs the child's complete help, parsing, validation, execution, and status lifecycle.
Commands at every nesting depth therefore share one input reader and one cancellation state without receiving the root command or raw request.

Command output and caller-side operations use `DATA` payloads while synchronous operation results return through the bidirectional input stream.
`Urpc::CliCommand` exposes:

- `command_name`, `argv`, and `caller_cwd`
- `run_subcommand(command_class, command_name:, argv:, **command_kargs)`
- `stdout(string)` and `stderr(string)`
- `glob(pattern)`
- `read_file_binary(path)` and `read_file_utf8(path)`
- `list_dir(path)` and `path_info(path)`
- `read_env(name)` and `list_env(include_values: false)`
- `read_stdin`
- `stdin_tty?`, `stdout_tty?`, and `stderr_tty?`
- `cancelled?` and `finished?`

Relative caller-side paths are resolved by `urpc-call-cli` against the submitted `caller_cwd`.
An asynchronous `{ type: :cancel }` input or a client input disconnect makes `cancelled?` true.
Any other asynchronous CLI input is a protocol error.
Long-running commands must check it at natural cancellation points and normally return status 130 when cancelled.

### Server execution

`Urpc::Server` is always the one owner of `server.lock` and the one reader of `submit.fifo`.
An executor controls where and how each accepted request runs.
The default is inline execution:

```ruby
Urpc::Server.new("service_key", &dispatch).run
```

Select another execution strategy with `executor:`:

```ruby
executor = Urpc::Executor::ThreadPool.new(size: 8)
Urpc::Server.new("service_key", executor:, &dispatch).run
```

The available executors are:

- `Urpc::Executor::Inline`, the default serial execution path
- `Urpc::Executor::ThreadPool`, a fixed number of reusable worker threads
- `Urpc::Executor::ThreadPerRequest`, one new thread per request with no limit
- `Urpc::Executor::ProcessPool`, a fixed number of pre-forked worker processes
- `Urpc::Executor::ProcessPerRequest`, one new process per request with no limit

All executors implement the same lifecycle:

```ruby
executor.start(paths:, handler:)
reservation = executor.reserve
executor.submit(reservation, accepted)
executor.close
```

The server calls `start` before acquiring `server.lock` or opening `submit.fifo`.
This lets process executors fork without inheriting service-ownership descriptors.
The server calls `reserve` before reading the next submit frame, so bounded executors do not create an extra application-level backlog.
`submit` transfers the accepted opaque frame to the reserved execution context.

The execution context owns the complete accepted-request path: hydrate the inline or file-backed request, open its output/input FIFOs, complete the bidirectional input handshake, construct `Urpc::Req`, and invoke the server handler.
A stalled bidirectional handshake therefore consumes one execution slot without blocking other available slots or the accept loop.

`Inline` reserves immediately and executes `submit` in the service-owner thread.
Handler exceptions propagate out of `Server#run`.

`ThreadPool` blocks `reserve` until one worker mailbox is idle.
Each worker executes one complete request at a time and then returns its mailbox to the idle queue.
`ThreadPerRequest` reserves immediately and starts a new thread from `submit`.
Unexpected exceptions escaping either thread executor use `abort_on_exception` and normally terminate the service process.

Process execution replaces the v1 broker's multi-registration fanout while preserving one service owner.
It provides real parallel Ruby execution despite the GVL and provides process isolation when needed.
The owner forwards accepted bytes before hydration; file-backed payloads remain in `calls/<id>.msgpack` until the selected process reads and unlinks them.

`ProcessPool` pre-forks each worker during `start`.
`reserve` waits for a worker-ready byte, and `submit` sends the accepted frame to that worker.
Unexpected worker exit terminates the owner run loop rather than silently reducing pool capacity.

`ProcessPerRequest` pre-forks one forker process during `start`.
For each accepted request, the forker creates a short-lived intermediate child, which forks the actual request child and exits immediately.
The forker waits only for that intermediate child before reporting ready again.
The request child is automatically reparented and reaped without PID tracking, a reaper thread, or global `SIGCHLD` changes.
Request children never inherit the service lock, submit FIFO, or forker control pipes.

The per-request process is an intentional crash-isolation boundary.
An exception or hard process failure that escapes request handling terminates only that request child; it is logged when possible, while the forker and service owner continue accepting calls.
If the failed request did not send a terminal frame, its client observes `Urpc::ServerDisconnected` when the request child's output FIFO closes.
The request child exits immediately after the handler block returns, so its request cannot outlive that block.
The handler must finish or close the request before returning; `Urpc::Dispatch` and `Urpc::Handler` do this automatically during normal execution.

Server close closes process work pipes.
Idle process workers and the forker observe EOF and exit.
Active thread or process requests may finish after owner close, but process workers hold no service-ownership descriptors.

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
