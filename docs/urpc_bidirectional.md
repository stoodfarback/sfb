# URPC Bidirectional Handlers

## Purpose

URPC streaming calls currently support server-to-client events through `Urpc::StreamServer`: a server handler receives a `Urpc::Req`, writes `:data` frames, then finishes with `:return` or `:error`.

Some calls need client-to-server messages while the response stream is still open:

| Use case | Client-to-server style | Example |
|---|---|---|
| Cancellation | Async | User presses Ctrl-C while a long-running task is streaming progress. |
| Confirmation prompt | Sync | Server asks "apply changes?", client sends `"y"` or `"n"`. |
| Input prompt | Sync | Server asks for a value, client sends the entered text. |
| Tool-use loop | Mixed | Server asks for approval between tool calls. |
| Client upload | Async or sync | Client sends chunks while the server streams status. |
| Keyboard/control events | Async | Client sends keystrokes, pause/resume, or similar controls. |

This design adds an explicit bidirectional mode for `StreamServer` handlers. Server-to-client events continue to use the normal response stream. Client-to-server messages use a per-call inbox FIFO owned by the broker and opened by the server and client.

## Scope

This is a `StreamServer` feature. It does not add first-class bidirectional support to basic `Urpc::Server` handlers.

That tradeoff is intentional. Bidirectional calls need `Urpc::Req`, and mixed-use handlers already have good-enough support through stream helpers. This design also adds a general `Urpc::CallHandler` base class so complex stream calls can be structured as call-specific objects without becoming bidirectional.

The broker owns inbox path allocation and cleanup. It creates the per-call FIFO, tells the server where to open it, and translates the server's internal `:inbox_ready` control frame into the client-visible `:inbox` response frame. It does not broker the later client-to-server messages written to the inbox FIFO.

## Naming

The feature name is `Bidirectional`.

The call-specific server base class is `Urpc::BidirectionalHandler`. The suffix matters: instances are per-call handler objects, not reusable transport objects.

The lower-level FIFO reader is `Urpc::Inbox`. The inbox is directional and concrete: it is the server's inbox for messages from the client. The broker, not `Urpc::Inbox`, owns the path and filesystem lifetime.

## Architecture

Existing URPC streaming path:

```text
client -> broker submit FIFO/request file -> server socket
server -> broker socket -> client reply FIFO
```

Bidirectional calls add a direct per-call FIFO path:

```text
client -> broker-owned inbox FIFO -> server
```

The client requests bidirectional mode in its submit frame. The broker creates `/tmp/urpc/inboxes/<call-id>.fifo`, includes that path in the backend request, and dispatches the call. The server opens the FIFO for reading, then sends a backend-only `[:inbox_ready, nil]` control frame. The broker translates that control frame into a client-visible `[:inbox, path]` response frame.

The server never sends an inbox path to the broker. The broker already owns the path, so the server only reports readiness.

After receiving `:inbox`, the client opens the FIFO for writing and writes `[:ready, nil]`. The server waits for that setup frame before running application code. After that, the client can send `:sync` and `:async` inbox frames directly to the server.

### Backend Request Metadata

The broker request sent to `StreamServer` gains internal metadata:

| Key | Value |
|---|---|
| `:bidirectional` | `true` when the submit frame requested bidirectional mode, otherwise `false`. |
| `:inbox_path` | Broker-owned FIFO path for bidirectional calls, otherwise `nil`. |

These fields are transport metadata. They must not be merged into RPC args or kwargs. `StreamServer` copies them onto `Urpc::Req` so `handle_bidirectional!` can validate the call and `Urpc::Inbox` can open the broker-owned path.

## Server API

### Call Site

A stream handler opts in explicitly through `Urpc::Req`:

```ruby
class Handler
  def llm_call(req)
    req.handle_bidirectional!(LlmCall, api_client:, log_writer:)
  end
end
```

`handle_bidirectional!` constructs a new per-call object, validates that it is a `Urpc::BidirectionalHandler`, then runs it.

### Bidirectional Handler

```ruby
class LlmCall < Urpc::BidirectionalHandler
  attr_accessor :api_client, :log_writer, :cancel_requested

  def initialize(req, api_client:, log_writer:)
    super(req)
    self.api_client = api_client
    self.log_writer = log_writer
  end

  def receive_async(value)
    self.cancel_requested = true if value == :cancel
  end

  def run!
    data(status: "starting")

    chunks.each do |chunk|
      break if cancel_requested
      data(chunk: chunk)
    end

    data(prompt: "Apply changes?")
    answer = receive
    finish(answer == "y" ? apply_changes : "aborted")
  rescue EOFError
    finish("client disconnected") if !finished?
  end
end
```

`Urpc::BidirectionalHandler` provides:

| Method | Meaning |
|---|---|
| `req` | The current `Urpc::Req`. |
| `args` | `req.args`. |
| `kargs` | `req.kargs`. |
| `stream` | `req.stream`. |
| `data(value)` | Send a normal `:data` response event. |
| `finish(value = nil)` | Send a terminal `:return` event. |
| `error(exception)` | Send a terminal `:error` event. |
| `finished?` | True after `finish` or `error`. |
| `send_frame(type, value)` | Send a low-level response frame. |
| `send_control(type, value)` | Send a backend-control frame to the broker. |
| `receive` | Block for the next sync inbox message. Raises `EOFError` on disconnect. |
| `receive_async(value)` | Optional hook for async inbox messages. Called in the inbox reader thread. |
| `on_disconnect` | Optional hook called when the inbox FIFO reaches EOF. |
| `disconnected?` | True after the client closes the inbox writer or dies. |

### Shared Call Handler

`Urpc::CallHandler` gives complex non-bidirectional stream calls the same per-call object style:

```ruby
class EmitReport < Urpc::CallHandler
  attr_accessor :formatter

  def initialize(req, formatter:)
    super(req)
    self.formatter = formatter
  end

  def run!
    data(formatter.header)
    data(formatter.body)
    "done"
  end
end

class Handler
  def emit_report(req)
    req.handle_with!(EmitReport, formatter:)
  end
end
```

`Urpc::CallHandler#handle!` calls `run!`, then sends the returned value as the terminal `:return` frame if the handler did not already call `finish` or `error`.

```ruby
class Urpc::CallHandler
  attr_accessor :req

  def initialize(req)
    self.req = req
  end

  def handle!
    result = run!
    finish(result) if !finished?
  rescue => e
    error(e) if !finished?
  end

  def run!
    raise("subclass must implement run!")
  end

  def args = req.args
  def kargs = req.kargs
  def stream = req.stream

  def data(value) = stream.data(value)
  def finish(value = nil) = stream.return(value)
  def error(exception) = stream.error(exception)
  def finished? = stream.is_finished
  def send_frame(type, value) = stream.write_response(type, value)
  def send_control(type, value) = stream.write_control(type, value)
end
```

`Urpc::BidirectionalHandler` subclasses `Urpc::CallHandler` and adds inbox setup and receive helpers:

```ruby
class Urpc::BidirectionalHandler < Urpc::CallHandler
  INBOX_OPEN_TIMEOUT = 1.0

  attr_accessor :inbox

  def handle!
    setup_inbox!
    super
  ensure
    inbox&.close
  end

  def setup_inbox!
    self.inbox = Urpc::Inbox.new(owner: self, path: req.inbox_path)
    inbox.start
    send_control(:inbox_ready, nil)
    inbox.await_ready!(timeout: INBOX_OPEN_TIMEOUT)
  end

  def receive = inbox.receive
  def disconnected? = inbox.disconnected?

  def receive_async(value); end
  def on_disconnect; end
end
```

### Req Helpers

`Urpc::Req` owns call-handler construction and validation:

```ruby
class Urpc::Req
  attr_accessor :args, :kargs, :stream, :bidirectional, :inbox_path

  def bidirectional? = bidirectional

  def handle_with!(klass, *args, **kargs)
    handler = klass.new(self, *args, **kargs)
    raise(ArgumentError, "#{klass} must be a Urpc::CallHandler") if !handler.is_a?(Urpc::CallHandler)
    handler.handle!
  end

  def handle_bidirectional!(klass, *args, **kargs)
    raise(ArgumentError, "call was not requested as bidirectional") if !bidirectional?
    handler = klass.new(self, *args, **kargs)
    raise(ArgumentError, "#{klass} must be a Urpc::BidirectionalHandler") if !handler.is_a?(Urpc::BidirectionalHandler)
    handler.handle!
  end
end
```

## Client API

The client starts with an explicit bidirectional stream call:

```ruby
s = client.bidirectional_stream(:llm_call, prompt: "refactor this")
```

`bidirectional_stream` returns an `EventStream`, just like `stream`, but the submit frame includes `SUBMIT_FLAG_BIDIRECTIONAL`. The flag tells the broker to create a per-call inbox FIFO and include its path in the backend request.

`EventStream` handles `:inbox` internally. Public event iteration should not yield `:inbox`; it should open the inbox writer, write `[:ready, nil]`, and continue to the next application event.

This applies to all public stream-event paths: `EventStream#next_event`, `EventStream#each_event`, multiplexed `Client#next_event`, and multiplexed `Client#each_event` must all skip internal `:inbox` frames.

New `EventStream` methods:

| Method | Meaning |
|---|---|
| `send_sync(value)` | Write `[:sync, payload]` to the inbox FIFO. |
| `send_async(value)` | Write `[:async, payload]` to the inbox FIFO. |
| `close_inbox` | Close the writer, causing EOF on the server reader. |
| `inbox_open?` | True after the `:inbox` frame has been handled. |
| `await_inbox` | Block until the inbox is open or the stream finishes/errors. |

Example:

```ruby
s = client.bidirectional_stream(:llm_call, prompt: "refactor this")

s.each_event do |event|
  case event.type
  when :data
    if event.data[:prompt]
      print("#{event.data[:prompt]} ")
      s.send_sync($stdin.gets&.chomp)
    elsif event.data[:chunk]
      print(event.data[:chunk])
    end
  end
end

result = s.result
```

Do not write to the inbox directly from a Ruby signal trap. `send_sync` and `send_async` perform IO and may take locks; signal handlers should set simple state or wake normal application code, which can then call `send_async(:cancel)`.

Do not add `EventStream#send(value)`. It would override Ruby's `Object#send`, and the explicit `send_sync` / `send_async` names make routing visible at the call site.

## Submit Flag

Bidirectional mode is requested through the submit envelope, not through RPC kwargs.

```ruby
Urpc::SubmitFrame::SUBMIT_FLAG_BIDIRECTIONAL = 0x04
```

Only `Client#bidirectional_stream` sets this flag. `Client#stream` remains a normal server-to-client stream, and `Client#cast` must not allow bidirectional mode.

## Frame Model

Response frames, backend-control frames, and inbox frames use the same packed frame shape, but they should have separate valid type sets.

```ruby
Urpc::Frames::RESPONSE_TYPES = %i[data return error inbox].freeze
Urpc::Frames::BACKEND_CONTROL_TYPES = %i[inbox_ready].freeze
Urpc::Frames::INBOX_TYPES = %i[ready sync async].freeze
Urpc::Frames::TERMINAL_TYPES = %i[return error].freeze
```

Server-to-client response frames:

| Type | Payload | Meaning |
|---|---|---|
| `:inbox` | FIFO path string | Client opens this path for writing. |
| `:data` | Any MessagePack value | Existing streaming data event. |
| `:return` | Any MessagePack value | Existing terminal success event. |
| `:error` | Error payload | Existing terminal failure event. |

Backend-control frames:

| Type | Payload | Meaning |
|---|---|---|
| `:inbox_ready` | `nil` | Server has opened the broker-owned inbox FIFO and is ready for the broker to tell the client. |

Client-to-server inbox frames:

| Type | Payload | Routing |
|---|---|---|
| `:ready` | `nil` | Setup frame consumed by `Urpc::Inbox`; it unblocks handler startup and is not delivered to application code. |
| `:sync` | Any MessagePack value | Pushed to the sync queue consumed by `receive`. |
| `:async` | Any MessagePack value | Delivered to `receive_async(value)` in the inbox reader thread. |

The broker should accept `:inbox_ready` only from a backend handling a call whose submit frame requested bidirectional mode. It should not forward `:inbox_ready` to the client. Instead, it sends `[:inbox, broker_owned_path]`.

The broker should not accept `:inbox` from backends as a response frame. It may write `:inbox` to the client only as its own translated frame, using the broker-owned path.

The broker should not accept `:ready`, `:sync`, or `:async` as response frames.

EOF is not a frame. FIFO EOF is transport state. It marks the inbox disconnected, calls `on_disconnect`, and unblocks pending `receive` calls by raising `EOFError`.

## Lifecycle

```text
1. Client starts a bidirectional stream call.
2. Client submit frame includes SUBMIT_FLAG_BIDIRECTIONAL.
3. Broker rejects bidirectional casts.
4. Broker creates /tmp/urpc/inboxes/<call-id>.fifo.
5. Broker dispatches the request to a StreamServer with bidirectional: true and inbox_path.
6. Stream handler calls req.handle_bidirectional!(LlmCall, ...).
7. Req constructs the Urpc::BidirectionalHandler subclass.
8. BidirectionalHandler starts an Urpc::Inbox reader for req.inbox_path.
9. Server emits backend-control frame [:inbox_ready, nil].
10. Broker translates it to client response frame [:inbox, inbox_path].
11. EventStream handles :inbox internally, opens the FIFO for writing, and writes [:ready, nil].
12. BidirectionalHandler waits up to 1s for the inbox reader to consume [:ready, nil].
13. BidirectionalHandler calls run!.
14. Server sends :data/:return/:error through the normal response stream.
15. Client sends :sync/:async frames through the inbox FIFO.
16. Cleanup closes/unlinks the inbox FIFO and closes the client writer.
```

Start the reader thread before emitting `:inbox_ready`. The reader thread opens the broker-owned FIFO for reading, consumes the client's `[:ready, nil]` frame, and then begins reading application inbox frames. `Urpc::Inbox` should implement this as a cancellable open/read handshake, such as nonblocking open/retry plus timed waits, so a timeout does not leave a thread stuck in a plain blocking `File.open` or blocking read.

Opening the inbox is a short protocol handshake, not application-level waiting. If the client does not open the FIFO and send `[:ready, nil]` within `Urpc::BidirectionalHandler::INBOX_OPEN_TIMEOUT`, `inbox.await_ready!` raises. `BidirectionalHandler#handle!` does not manually send an error frame; the exception flows through the normal `StreamServer` rescue path, which emits `:error` if the response stream is not already finished. The broker still closes and unlinks the FIFO when the call is finished or abandoned.

## Cancellation And Disconnect

Cancellation has two levels:

```text
first Ctrl-C  -> s.send_async(:cancel) -> application-level graceful cancellation
second Ctrl-C -> client exits/closes FIFO -> server sees EOF
```

`:cancel` is an application convention, not a URPC protocol frame. A handler may choose `:cancel`, `[:cancel, reason]`, or any other async value.

Hard disconnect is protocol-level and comes from FIFO EOF. The server sees it through:

- `disconnected?`
- `on_disconnect`
- `EOFError` raised from `receive`

There is no custom disconnect exception in the initial design. `EOFError` is built in and accurately describes the FIFO state.

## Threading

`Urpc::Inbox` reads the inbox FIFO in a background thread.

`receive_async(value)` and `on_disconnect` run in that reader thread. They should be fast: set state, push to a queue, or wake another thread. Slow work belongs in `run!`.

`ResponseStream` serializes high-level writes and terminal-state transitions with a mutex, so `data`, `finish`, and `error` are safe to call from multiple threads. `send_frame` is a low-level response helper; it serializes the write, but callers should not use it as a general response API after the application stream has started. The preferred style is still to send response events from `run!`; callbacks should send immediate responses only when they need to.

Backend-control writes such as `:inbox_ready` are separate from response writes. They are consumed by the broker and must not be yielded to clients, logged as application response frames, or accepted as response frames from non-bidirectional calls.

## Test Plan

Add integration tests for:

- `req.handle_with!` runs a `Urpc::CallHandler` subclass and auto-finishes with the value returned by `run!`.
- `req.handle_bidirectional!` rejects non-`Urpc::BidirectionalHandler` classes.
- `req.handle_bidirectional!` rejects calls that were not submitted with the bidirectional flag.
- Bidirectional client submission sets `SUBMIT_FLAG_BIDIRECTIONAL`; normal `stream` does not.
- Broker rejects bidirectional casts.
- Broker creates the inbox FIFO at `/tmp/urpc/inboxes/<call-id>.fifo`.
- Backend request includes bidirectional metadata and the broker-owned inbox path.
- Server sends `:inbox_ready` without a path; broker translates it to client `:inbox` with the broker-owned path.
- Broker rejects backend-provided `:inbox` response frames.
- Client writes `[:ready, nil]`; server consumes it before running application code.
- `:inbox` is emitted, handled internally, and not yielded from public event iteration.
- `await_inbox` opens the inbox before application data arrives.
- Sync prompt: server sends prompt, client sends `send_sync`, server returns an answer-dependent result.
- Async cancel: client sends `send_async(:cancel)`, server callback sets a flag, and long-running work stops.
- Client disconnect: `close_inbox` causes server `receive` to raise `EOFError`.
- Broker validation: `:inbox_ready` is a backend-control frame; `:ready`, `:sync`, and `:async` are not valid response frames.
- Cleanup: inbox FIFO is unlinked after success, error, and client disconnect.
- Multiplexing: bidirectional and normal streams can be used together with `Client#each_event`.
