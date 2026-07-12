# URPC v2 migration

URPC v2 is a brokerless replacement for URPC v1.
This document lists application-facing differences from v1.
The authoritative v2 contract is `docs/urpc_v2.md`.

Review note: v2 is a replacement, not a backwards-compatible update, and every v1 user will be migrated manually.
This is a focused migration guide, not an inventory of v1 features or removals; something existing in v1 does not imply that it belongs in v2 or needs mention here.
The CLI client migration lives in `../urpc_call_rs`.

## Service keys

Service keys are now strict: they must match `[0-9a-z_]+`.

## Service ownership

The v1 broker allowed multiple server processes to register the same key and dispatched calls among them.
In v2, only one service owner may register a key.
Replace multi-registration with one service owner that performs fanout itself:

- `Urpc::Executor::ThreadPool` when calls are ordinary bounded work and can share one Ruby process.
- `Urpc::Executor::ThreadPerRequest` for long-lived calls where each request should get its own thread.
- `Urpc::Executor::ProcessPool` when the work should remain process-isolated but bounded to a fixed worker count.
- `Urpc::Executor::ProcessPerRequest` for process-per-call isolation with no built-in limit.

Pass the executor to the one service-owner class:

```ruby
executor = Urpc::Executor::ProcessPool.new(size: 8)
Urpc::Server.new(RPC_KEY, executor:, &dispatch).run
```

See the "Server fanout" section in `docs/urpc_v2.md` for examples.

## Servers and dispatch

Servers now receive each request through a block.
Use `Urpc::Dispatch` for automatic method lookup, return handling, and exception conversion.

For an existing shared handler object with ordinary methods, bind each method into the dispatch map:

```ruby
handler = RpcHandler.new
dispatch = Urpc::Dispatch.new(
  search: handler.method(:search),
  show: handler.method(:show),
)

Urpc::Server.new(RPC_KEY, &dispatch).run
```

Dispatch mappings are duck-typed:

- an object that responds to `new` is treated as a per-request handler factory and evaluated as `handler.new(req).run`
- an object that responds to `to_proc`, including a lambda, proc, or bound method, is normalized into an anonymous `Urpc::Handler` subclass

Simple inline methods can therefore be written directly:

```ruby
dispatch = Urpc::Dispatch.new(
  ping: -> { :pong },
  add: ->(left, right) { left + right },
)
```

The lower-level alternative is a server block that owns the `Urpc::Req` lifecycle itself:

```ruby
Urpc::Server.new(RPC_KEY) do |req|
  value = handler.public_send(req.name, *req.args, **req.kargs)
  req.finish(value)
end.run
```

## Handler classes

Use an `Urpc::Handler` subclass when a request needs streaming helpers, bidirectional input, custom initialization, or an explicit lifecycle:

```ruby
class Watch < Urpc::Handler
  def call(key)
    data("#{key}:one")
    data("#{key}:two")
    "done"
  end
end

dispatch = Urpc::Dispatch.new(watch: Watch)
```

`Urpc::Handler#call` replaces `Urpc::CallHandler#run!`.
Returning from `call` sends the terminal result unless the handler already called `finish`, `error`, or closed the request.
Ordinary and streaming calls use the same server and handler path.

## CLI commands

`Urpc::CliCommand` remains the server-side base class for commands invoked by `urpc-call-cli`, now built on the v2 `Urpc::BidirectionalHandler`.
Map command classes directly through `Urpc::Dispatch`; `Urpc::Req#handle_bidirectional!` and `Urpc::StreamServer` are gone:

```ruby
dispatch = Urpc::Dispatch.new(
  verify: VerifyCommand,
  email_search: EmailSearchCommand,
)

Urpc::Server.new(RPC_KEY, &dispatch).run
```

Existing command subclasses keep their command-facing hooks and helpers: `set_defaults!`, `parse_argv!`, `validate!`, `perform!`, `help_text`, stdout/stderr streaming, caller-side filesystem/environment/stdin operations, and cancellation.
The requested RPC method now supplies `command_name`; constructors no longer receive it explicitly.
The caller working-directory attribute is now named `caller_cwd` instead of `cwd` so it cannot be confused with the server process working directory.

The CLI request and terminal result are simpler in v2:

- the request uses the ordinary RPC keyword arguments `argv:` and `caller_cwd:` instead of one versioned positional hash
- the terminal return is the integer exit status instead of `{ status: status }`
- the default help check recognizes only a lone `-h` or `--help`

Only `OptionParser::ParseError` and `ArgumentError` from `parse_argv!` or `validate!` become usage output with status 2.
The same exceptions from `perform!` are now remote command failures; v1 accidentally presented them as user input errors.

Do not instantiate another `Urpc::CliCommand` to implement a subcommand.
One CLI RPC request has one bidirectional input reader owned by its top-level command.
Dispatch subcommands from that command into plain application objects or methods instead.

## Client streams

`client.stream` now returns an enumerable `Urpc::Stream`.
Iteration yields only `DATA` payloads; the terminal return value remains available through `result`:

```ruby
stream = client.stream(:watch, "key")
stream.each { |data| puts(data) }
result = stream.result
```

Code using event objects should replace `event.type == :data` and `event.data` with direct iteration values.
Terminal remote errors are raised during iteration or by `result`.

## Client failures

There is no broker in v2, so `Urpc::BrokerUnavailable` is gone.
Use `Urpc::NoServerError` when no service becomes available or submission fails before the server owns the call.
`Urpc::TimeoutException` means the call deadline expired; `Urpc::ServerDisconnected` means an attached server-side call disappeared without completing.
All three inherit from `Urpc::TransportError`, which clients can rescue when they do not need to distinguish the failure phase.
`Urpc::RemoteException` remains separate because it represents an application exception raised by the remote handler.
For both timeout and server-disconnected, the call was submitted and may have executed partially.

## Bidirectional input

The bidirectional API uses `input` terminology in place of v1 `inbox` terminology.

Client method renames:

| v1 | v2 |
|---|---|
| `bidirectional_stream(...)` | `bidirectional(...)` |
| `await_inbox` | `await_input` |
| `inbox_open?` | `input_open?` |
| `close_inbox` | `close_input` |

`send_sync(value)` and `send_async(value)` keep their names.

Protocol and implementation names also use input terminology:

| v1 term | v2 term |
|---|---|
| inbox FIFO | input FIFO |
| inbox frame | input frame |
| inbox path | input path |
