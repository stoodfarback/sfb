# URPC CLI Server

Status: Proposal

## Purpose

URPC already supports structured Ruby calls through `Urpc::Client`, streaming responses through `Urpc::StreamServer`, and client-to-server messages through bidirectional streams.

This specification defines an opinionated CLI-focused layer on top of bidirectional URPC. The goal is to make a remote server command feel like a local command:

```sh
urpc-call-cli ledger_llm_consolidate_tmp_v1 verify
urpc-call-cli ledger_llm_consolidate_tmp_v1 email_search -n 20 'from:amazon'
urpc-call-cli ledger_llm_consolidate_tmp_v1 email_show 196f5d3fbc7f2d88
```

The client does not interpret command arguments. The server owns command semantics, usage text, validation, defaults, and `--help`.

The key architectural idea is that the server acts through the client for caller-side effects. The server may read and write its own host state directly, but when it needs the caller's workspace, stdin, environment, or terminal output, it asks the client over the bidirectional protocol.

This keeps the design coherent across VM boundaries: the server can run on the host while the CLI client runs inside a VM, and all VM-local filesystem/env/stdin access stays on the client side.

## Implementation Status

The transport foundation already exists:

| Layer | Status |
|---|---|
| `Urpc::Client#bidirectional_stream` | Implemented. |
| `Urpc::EventStream#send_sync` / `send_async` / `close_inbox` | Implemented. |
| `Urpc::BidirectionalHandler` and `Urpc::Inbox` | Implemented. |
| Broker-owned inbox FIFO setup and cleanup | Implemented. |

The CLI layer now exists on top of that foundation:

| Layer | Status |
|---|---|
| `Urpc::CliCommand` | Implemented. |
| `bin/urpc-call-cli` Ruby client | Implemented as the reference client. |
| CLI operation helpers and client operation dispatch | Implemented. |
| Rust `urpc-call-cli` | Optional follow-up after the Ruby client is covered by tests. |

## Scope

V1 includes:

| Feature | Status |
|---|---|
| Raw argv forwarding | Included |
| Server-owned parsing and help | Included |
| Streaming stdout/stderr | Included |
| Ctrl-C cancellation | Included |
| Implicit client-death cancellation | Included |
| Caller-side `glob` | Included |
| Caller-side `read_file_binary` | Included |
| Caller-side `read_file_utf8` | Included |
| Caller-side `list_dir` | Included |
| Caller-side `path_info` | Included |
| Caller-side `read_env` | Included |
| Caller-side `list_env` | Included |
| Caller-side `read_stdin` | Included |
| Caller-side stdio TTY checks | Included |
| TTY/raw keyboard mode | Deferred |
| Semantic keyboard events | Deferred |
| Caller-side writes | Deferred |

Raw TTY behavior is intentionally out of scope for this layer. A future TUI-focused server/client can handle raw terminal mode, keyboard events, PTYs, resize handling, and richer interactive semantics.

## Command Line

`urpc-call-cli` has this shape:

```text
urpc-call-cli [client-options] <rpc_key> <command> [argv...]
```

Only client options before `<rpc_key>` are parsed by the client. Everything after `<command>` is preserved and sent to the server as command argv.

Suggested client options:

| Option | Meaning |
|---|---|
| `--wait-for-server SECONDS` | Wait for a backend to register. Defaults to `5`. |
| `--root PATH` | Optional override for `URPC_ROOT`; the client must apply it before the first `Urpc.root` access. |

Command flags such as `--help`, `--files`, `-n`, or `--limit` belong to the server command, not the client.

## Transport Shape

The URPC method name is the CLI command name.

The client opens a bidirectional stream:

```ruby
Urpc::Client.new(rpc_key, wait_for_server: 5).bidirectional_stream(:verify, request)
```

The initial request is the single positional RPC argument (no keyword arguments). It is a single hash:

```ruby
{
  version: 1,
  argv: [],
  cwd: "/workspace",
}
```

Fields:

| Field | Type | Meaning |
|---|---|---|
| `:version` | Integer | CLI protocol version. V1 is `1`. |
| `:argv` | Array of String | Raw command argv after the command name. |
| `:cwd` | String | Client current working directory at invocation time. |

The initial request does not include environment variables. Commands that need client environment values request them with `:read_env` or `:list_env`.

The request must have exactly one positional argument and no keyword arguments. `Urpc::CliCommand` should reject invalid shapes with `ArgumentError` before command-specific parsing runs.

Protocol examples use Ruby symbols for hash keys and enum-like values. On the wire those are sfb MessagePack symbol extension values. Non-Ruby clients must support that extension or explicitly normalize their decoded values to the same Ruby-facing shape.

## Client Behavior

At a high level, `urpc-call-cli`:

1. Parses only client options before `<rpc_key>`, then extracts `<rpc_key>`, `<command>`, and raw `[argv...]`.
2. Opens a bidirectional stream where the URPC method is `<command>` and the single positional arg is `{ version: 1, argv:, cwd: Dir.pwd }`.
3. For each server `:data` event:
   - `type: :stdout` → write `:data` bytes to local stdout.
   - `type: :stderr` → write `:data` bytes to local stderr.
   - `type: :op` → perform the requested client operation and reply with an inbox `:sync` message shaped like `{ type: :op_result, ok:, value: ... }` (or `{ ..., error: ... }`).
4. On Ctrl-C, sends `{ type: :cancel, reason: :interrupt }` as an inbox `:async` message, then continues streaming until the command exits (or a local grace policy gives up).
5. Exits with the returned `{ status: Integer }` from the terminal `:return` frame.

The client should treat malformed CLI protocol events as remote protocol failures: print a concise error to stderr, close the inbox, and exit nonzero. This is separate from command usage errors, which are represented by normal stdout/stderr events plus `{ status: 2 }`.

## Server API

### Stream Server Handler

Applications expose commands as ordinary `StreamServer` handler methods. Each method delegates to a per-call command class with `req.handle_bidirectional!`:

```ruby
class HarnessCliHandler
  attr_accessor :config

  def initialize(config:)
    self.config = config
  end

  def verify(req)
    req.handle_bidirectional!(VerifyCommand, command_name: __method__, config:)
  end

  def email_search(req)
    req.handle_bidirectional!(EmailSearchCommand, command_name: __method__, config:)
  end

  def email_show(req)
    req.handle_bidirectional!(EmailShowCommand, command_name: __method__, config:)
  end
end

Urpc::StreamServer.new(
  "ledger_llm_consolidate_tmp_v1",
  HarnessCliHandler.new(config:),
).run
```

This keeps command dispatch in normal Ruby code and matches the existing URPC per-call pattern.

Unknown commands are handled like any other missing URPC method, except applications can define their own fallback if they want custom command discovery or help.

### CLI Command

Each command is a per-call object:

```ruby
class VerifyCommand < Urpc::CliCommand
  def help_text
    "Usage: verify\n"
  end

  def validate!
    raise(ArgumentError, "verify takes no arguments") if !argv.empty?
  end

  def perform!
    files = glob("inbox_review/*.yml").sort.to_h do |path|
      [File.basename(path), read_file_utf8(path)]
    end

    verifier.verify(files:)
    stdout("ok\n")
    0
  end
end
```

`Urpc::CliCommand` subclasses `Urpc::BidirectionalHandler`.

The `Urpc::CliCommand` base class is responsible for extracting the CLI request hash from `req.args.first` and exposing `version`, `argv`, and `cwd` as attributes. It should raise `ArgumentError` for invalid request shapes.

Required request validation:

| Check | Error |
|---|---|
| `req.args.length == 1` | `ArgumentError` |
| `req.kargs.empty?` | `ArgumentError` |
| Request is a Hash | `ArgumentError` |
| `:version == 1` | `ArgumentError` |
| `:argv` is an Array of String | `ArgumentError` |
| `:cwd` is a non-empty String | `ArgumentError` |

Suggested base attributes:

| Attribute | Meaning |
|---|---|
| `command_name` | Command name passed by the handler method. |
| `argv` | Raw command argv. |
| `cwd` | Client current working directory. |
| `cancel_requested` | Set by explicit interrupt or client disconnect. |

Suggested lifecycle:

```ruby
def run!
  set_defaults!

  status =
    if help_requested?
      stdout(help_text)
      0
    else
      parse_argv!
      validate!
      perform!
    end

  { status: status || 0 }
rescue OptionParser::ParseError, ArgumentError => e
  stderr("#{e.message}\n\n")
  stderr(help_text)
  { status: 2 }
end
```

`perform!` returns a process exit status. `Urpc::CliCommand#run!` wraps that status in the CLI protocol return hash.

Status values should be integers in the normal process range `0..255`; `nil` is treated as `0`. Invalid statuses should raise instead of being silently coerced.

Suggested hooks:

| Hook | Default |
|---|---|
| `set_defaults!` | No-op. |
| `help_requested?` | True when argv contains `-h` or `--help`. |
| `parse_argv!` | No-op. |
| `validate!` | No-op. |
| `perform!` | Raises `NotImplementedError`. |
| `help_text` | `"Usage: #{command_name}\n"`. |

Suggested helpers:

| Helper | Meaning |
|---|---|
| `stdout(data)` | Stream bytes to client stdout. |
| `stderr(data)` | Stream bytes to client stderr. |
| `glob(pattern)` | Ask client to expand a glob against client filesystem. |
| `read_file_binary(path)` | Ask client to read a file as raw bytes (ASCII-8BIT). |
| `read_file_utf8(path)` | Ask client to read a file as validated UTF-8 text. |
| `list_dir(path)` | Ask client to list a directory. |
| `path_info(path)` | Ask client for existence/type metadata about a path. |
| `read_env(name)` | Ask client for one environment variable. |
| `list_env(include_values: false)` | Ask client for environment names or values. |
| `read_stdin` | Ask client to read remaining stdin. |
| `stdin_tty?` | Ask whether client stdin is a TTY. |
| `stdout_tty?` | Ask whether client stdout is a TTY. |
| `stderr_tty?` | Ask whether client stderr is a TTY. |
| `cancelled?` | Whether interrupt/disconnect cancellation has been requested. |

Command code should use these helpers for caller-side state. It should not assume `cwd` paths exist on the server filesystem.

The filesystem/env/stdin helpers should share one internal operation helper:

```ruby
def client_op(payload)
  data(payload.merge(type: :op))
  result = receive
  raise("malformed cli op result") if !valid_op_result?(result)
  raise(result[:error][:message]) if !result[:ok]
  result[:value]
end
```

The exact implementation can be cleaner than this sketch, but the important behavior is that one helper owns operation framing, result validation, and failed operation handling.

## Response Stream Protocol

Server-to-client command events are sent as URPC `:data` events. The `:data` payload is a CLI protocol hash.

### Stdout

```ruby
{
  type: :stdout,
  data: "text or bytes",
}
```

The client writes the event's `:data` value to its stdout without adding formatting.

### Stderr

```ruby
{
  type: :stderr,
  data: "text or bytes",
}
```

The client writes the event's `:data` value to its stderr without adding formatting.

### Client Operation Request

```ruby
{
  type: :op,
  op: :read_file_utf8,
  path: "inbox_review/001.yml",
}
```

The client performs the requested caller-side effect and replies over the bidirectional inbox with an operation result.

V1 operations are synchronous from the server command's perspective. A command sends one operation request, waits for the next `:sync` inbox response, then continues. There are no operation ids in v1.

### Normal Completion

Normal command completion uses the URPC terminal `:return` frame:

```ruby
{
  status: 0,
}
```

The client exits with `:status`.

### Remote Error

Unhandled server exceptions use the normal URPC terminal `:error` frame. `urpc-call-cli` should print a concise remote error to stderr and exit nonzero.

Command usage errors should normally be caught by `Urpc::CliCommand`, written to stderr, and returned as status `2` instead of becoming URPC transport errors.

## Inbox Protocol

Client-to-server CLI messages are written through the bidirectional inbox.

### Operation Result

Operation results are sent as `:sync` inbox frames:

```ruby
{
  type: :op_result,
  ok: true,
  value: "file contents",
}
```

Failure shape:

```ruby
{
  type: :op_result,
  ok: false,
  error: {
    exception: "Errno::ENOENT",
    message: "No such file or directory @ rb_sysopen - missing.yml",
  },
}
```

Unsupported operations are ordinary failed operation results:

```ruby
{
  type: :op_result,
  ok: false,
  error: {
    exception: "ArgumentError",
    message: "unsupported cli op: read_socket",
  },
}
```

### Cancellation

Explicit cancellation is sent as an `:async` inbox frame:

```ruby
{
  type: :cancel,
  reason: :interrupt,
}
```

`urpc-call-cli` sends this when it receives Ctrl-C. The client should continue reading server output until the command exits or a local grace policy decides to give up.

#### Suggested Ctrl-C Policy

`urpc-call-cli` should implement a multi-stage Ctrl-C policy that balances cooperative cancellation with a predictable local escape hatch:

1. First Ctrl-C:
   - Send the `:cancel` async message to the server (or mark it pending if the inbox is not open yet).
   - If `stderr.tty?`, print a short status line to stderr such as `"\n\nsent Ctrl-C to server (press again to force quit)\n"`.
2. Second Ctrl-C within 5 seconds of the first:
   - Close the inbox writer (server will observe disconnect and `Urpc::CliCommand#on_disconnect` can mark cancellation).
   - Continue streaming output while waiting up to 1 second for the command to exit.
   - If it does not exit within 1 second, exit locally with status `130`.
3. Third Ctrl-C while in the 1-second forced-quit wait:
   - Exit immediately with status `130`.

Implementation notes:

- Do not write to the inbox from the Ruby signal handler itself. The signal handler should only record state; normal application code sends the async cancel once it is safe to do so.
- Use a monotonic clock for the 5-second window and 1-second forced-quit wait.

If the client process exits, crashes, or closes the inbox, the server receives the normal bidirectional disconnect path. `Urpc::CliCommand#on_disconnect` should mark the command cancelled.

Suggested base behavior:

```ruby
def receive_async(value)
  self.cancel_requested = true if value[:type] == :cancel
end

def on_disconnect
  self.cancel_requested = true
end
```

Long-running commands should check `cancelled?` at useful boundaries.

## Client Operations

All relative paths and patterns are interpreted by the client relative to the initial `:cwd`.

The protocol is not a security boundary. In intended use, the server is trusted and may ask the client to do anything the CLI protocol supports. The operation set is still explicit so failures are debuggable and future client implementations can report unsupported operations cleanly.

The client should resolve relative paths by joining them to the captured `cwd`, not the process cwd at the moment the operation is handled. Operation result paths should use the same relative/absolute style as the request when practical.

### `:glob`

Request:

```ruby
{
  type: :op,
  op: :glob,
  pattern: "inbox_review/*.yml",
}
```

Result value:

```ruby
["inbox_review/001.yml", "inbox_review/002.yml"]
```

Relative patterns return relative paths. Absolute patterns return absolute paths.

### `:read_file_binary`

Request:

```ruby
{
  type: :op,
  op: :read_file_binary,
  path: "inbox_review/001.yml",
}
```

Result value is the exact file bytes as an ASCII-8BIT String, packed on the wire as MessagePack `bin`.
This is the byte-faithful primitive: clients read with `File.binread` and preserve every byte, including any leading BOM.

### `:read_file_utf8`

Request:

```ruby
{
  type: :op,
  op: :read_file_utf8,
  path: "inbox_review/001.yml",
}
```

Result value is the file content as a validated UTF-8 String, packed on the wire as MessagePack `str`.
The client reads with `mode: "r:BOM|UTF-8"`, which strips a single leading UTF-8 BOM, then validates and raises a clear per-path error (e.g. `not valid UTF-8: <path>`) when `!content.valid_encoding?`.

The validation is mandatory and must run on the client before the value is returned.
`r:BOM|UTF-8` does not itself validate the bytes, and MessagePack packs an invalid-UTF-8 `str` without complaint, so an unvalidated string would reach the server tagged UTF-8-but-invalid and fail far downstream instead of at the boundary.

Note the BOM asymmetry: `read_file_binary` preserves a leading BOM while `read_file_utf8` strips it, so the two ops return content that differs by those bytes for BOM-prefixed files.
Use `read_file_binary` when you need byte-exact content.

### `:list_dir`

Request:

```ruby
{
  type: :op,
  op: :list_dir,
  path: "inbox_review",
}
```

Result value:

```ruby
[
  { name: "001.yml", path: "inbox_review/001.yml", type: :file },
  { name: "archive", path: "inbox_review/archive", type: :dir },
]
```

Known entry types:

| Type | Meaning |
|---|---|
| `:file` | Regular file. |
| `:dir` | Directory. |
| `:symlink` | Symbolic link. |
| `:other` | Anything else. |

### `:path_info`

Request:

```ruby
{
  type: :op,
  op: :path_info,
  path: "inbox_review/001.yml",
}
```

Result value:

```ruby
{ exists: true, file: true, directory: false, symlink: false }
```

| Field | Meaning |
|---|---|
| `exists` | `File.exist?` — follows symlinks. |
| `file` | `File.file?` — follows symlinks. |
| `directory` | `File.directory?` — follows symlinks. |
| `symlink` | `File.symlink?` — describes the path itself, does not follow. |

A missing path returns all fields false, never an error.
Because `exists` follows symlinks while `symlink` does not, a broken symlink reports `exists: false, symlink: true`; detect it with `symlink && !exists`.

### `:read_env`

Request:

```ruby
{
  type: :op,
  op: :read_env,
  name: "LEDGER_FILE",
}
```

Result value is a String or `nil`.

### `:list_env`

Request names only:

```ruby
{
  type: :op,
  op: :list_env,
}
```

Result value:

```ruby
["HOME", "LEDGER_FILE", "PATH"]
```

Request values:

```ruby
{
  type: :op,
  op: :list_env,
  include_values: true,
}
```

Result value:

```ruby
{
  "HOME" => "/home/me",
  "LEDGER_FILE" => "./ledger/ledger.journal",
  "PATH" => "/usr/bin:/bin",
}
```

### `:read_stdin`

Request:

```ruby
{
  type: :op,
  op: :read_stdin,
}
```

Result value is the remaining stdin content as a String. Repeated calls after EOF return an empty String.

This is enough for commands like:

```sh
urpc-call-cli ledger_llm_consolidate_tmp_v1 email_search -
```

### `:stdin_tty`, `:stdout_tty`, `:stderr_tty`

Request:

```ruby
{
  type: :op,
  op: :stdout_tty,
}
```

Result value is true if the corresponding caller-side stdio stream is a TTY. It is false when the stream is not a TTY or when the stream is closed.

## Test Coverage

`test/urpc_cli_server_test.rb` covers the Ruby reference path through a real broker, `StreamServer`, and `bin/urpc-call-cli` process:

| Behavior | Covered |
|---|---|
| Server-owned help/status `0` | Yes |
| Validation/status `2` | Yes |
| stdout/stderr/status forwarding | Yes |
| Caller-side `glob`, `read_file_binary`, `read_file_utf8`, `list_dir`, `path_info`, `read_env`, `list_env`, `read_stdin` | Yes |
| `read_file_utf8` BOM stripping and invalid-UTF-8 boundary error | Yes |
| Caller-side stdio TTY checks | Yes |
| Raw argv forwarding after command name | Yes |
| Request shape validation | Yes |
| Unsupported client operation failure | Yes |
| Malformed CLI event failure | Yes |
| Ctrl-C async cancellation | Yes |

Use the Ruby implementation and tests as the contract for any Rust client.

## Example: Verify

The `verify` command does not need client attachment flags. The command already knows which caller-side files it needs.

Client invocation:

```sh
urpc-call-cli ledger_llm_consolidate_tmp_v1 verify
```

Server command:

```ruby
class VerifyCommand < Urpc::CliCommand
  def validate!
    raise(ArgumentError, "verify takes no arguments") if !argv.empty?
  end

  def perform!
    paths = glob("inbox_review/*.yml").sort
    files = paths.to_h do |path|
      [File.basename(path), read_file_utf8(path)]
    end

    verifier.verify(files:)
    stdout("ok\n")
    0
  end
end
```

This replaces a bespoke local script that knows how to gather files. The file-gathering behavior moves to the server command, but actual caller-side reads still happen through the client.

## Example: Email Search

Client invocation:

```sh
urpc-call-cli ledger_llm_consolidate_tmp_v1 email_search -n 20 'from:amazon'
```

The server command parses `-n`, validates the query, optionally calls `read_stdin` when argv is `["-"]`, queries host-side services, then streams formatted output:

```ruby
class EmailSearchCommand < Urpc::CliCommand
  attr_accessor :limit, :query_args

  def set_defaults!
    self.limit = 5
  end

  def parse_argv!
    parser = OptionParser.new do |o|
      o.banner = "Usage: email_search [-n N|--limit=N] QUERY|-"
      o.on("-n", "--limit N", Integer) { self.limit = it }
    end
    self.query_args = parser.parse(argv.dup)
  end

  def validate!
    raise(ArgumentError, "query required") if query_args.empty?
    raise(ArgumentError, "stdin mode must be the only query argument") if query_args.include?("-") && query_args.length > 1
  end

  def perform!
    query = query_args == ["-"] ? read_stdin.strip : query_args.join(" ").strip
    raise(ArgumentError, "query required") if query.empty?

    messages = Urpc::Client.new("agent_mail_v1").search(q: query, limit:)
    stdout(InboxReview::EmailCliFormatter.new.format_list(messages))
    0
  end
end
```

## Deferred: Caller-Side Writes

Writes are a natural future operation.
When added, they mirror the read split rather than a single ambiguous `write_file`:

| Op | Behavior |
|---|---|
| `write_file_binary` | Write the given bytes as-is. |
| `write_file_utf8` | Require the given String be valid UTF-8 (raise otherwise) and write it as UTF-8. |

```ruby
{
  type: :op,
  op: :write_file_binary,
  path: "out.txt",
  data: "contents",
}
```

Writes are intentionally deferred because their behavior needs more UX choices:

| Question | Examples |
|---|---|
| Existing files | Overwrite, fail if exists, append. |
| Parent directories | Require existing parent, create parents. |
| Atomicity | Direct write, temp file and rename. |
| Permissions | Preserve mode, explicit mode, default mode. |
| Binary vs text | `write_file_binary` preserves bytes; `write_file_utf8` validates UTF-8, like the read split. |

The architecture supports it, but V1 does not need it.

## Deferred: TUI Mode

This CLI layer does not put the local terminal in raw mode and does not forward keyboard events.

A future TUI-oriented protocol should be separate. It can support:

| Feature | Notes |
|---|---|
| Raw terminal mode | Client restores terminal in `ensure`. |
| Keyboard bytes | Preserve escape sequences and control bytes. |
| Resize events | Send rows/cols changes. |
| PTY-like semantics | Better match full-screen tools. |
| Semantic key events | Optional higher-level layer if byte mode is insufficient. |

Keeping TUI mode separate keeps `urpc-call-cli` small and predictable.

## Appendix: Rust Client

A Rust implementation of `urpc-call-cli` is valuable because Ruby startup is often 100-300ms, while a small Rust binary can start effectively instantly.

The CLI protocol does not require the client to be Ruby. A Rust client implements a focused URPC subset: bidirectional non-cast submission, MessagePack values, response FIFO reads, inbox FIFO writes, and the CLI events defined in this document.

The Ruby source remains the transport reference for a port:

| Source | Contract |
|---|---|
| `lib/urpc/submit_frame.rb` | Submit envelope constants, flags, name encoding, and wait-for-server encoding. |
| `lib/urpc/call.rb` | Request body shape and request/reply/inbox path derivation. |
| `lib/urpc/frames.rb` | Response, backend-control, and inbox frame packing. |
| `lib/urpc/event_stream.rb` | Client-side inbox setup, `:inbox` handling, and sync/async sends. |
| `lib/sfb/msgpack_init.rb` | MessagePack extension registrations, including Ruby symbols. |

The Rust client sends the command name as the URPC method, sends the initial request as the single positional argument, and sends no keyword arguments. It may start with file-backed request bodies only; inline submit support is an optimization rather than a CLI protocol requirement.

This keeps Rust support practical without duplicating the full URPC wire specification here.
