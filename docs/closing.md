# How a connection closes

This page explains when h1 closes an HTTP/1.1 connection and how. Read it when a handler needs to know what happens after a cancel or a `Connection: close`, when you read the `{closed, Reason}` event or a connection's exit reason, or before you change the close code in `h1_connection.erl`.

HTTP/1.1 has no way to end one exchange without ending the connection. So every close comes down to two decisions:

1. **Which response is the last one.** h1 keeps one close point per connection: the first stream it will not serve. Streams below it are answered. Streams at or above it never are, and their handlers never run.
2. **How the server closes once that response is out:** at once, or staged so a reset cannot destroy what the client has not read yet.

## What sets the last response

| Event | Last response | Side |
| --- | --- | --- |
| A request carries `Connection: close`, or is HTTP/1.0 without `keep-alive` | that request's response | server |
| Your handler sets `Connection: close` on its response | that response | server |
| `h1:send_goaway/1,2` | the response in progress | server |
| `max_keepalive_requests` reached (default 100) | the response in progress | server |
| Your handler answers before the request body has arrived (early response) | that response | server |
| A malformed or over-limit request is answered with an error status | the error response | server |
| `h1:cancel/2,3` on a stream, with an earlier pipelined response still owed | that earlier response | server |
| `h1:cancel/2,3` on a stream, with nothing earlier owed | none: close now | server |
| `h1:cancel/2,3` on a client request | the response to the request before it | client |

The close point only moves down. If two events name different streams, the earlier one wins. For example, cancelling requests 2 and 3 in either order closes the client after response 1.

Input that arrives after the last request is read and discarded, never parsed.

## How the server closes

Once the last response is on the wire, the server closes **at once** unless input may still be unread. Input may be unread when one of these holds:

- the last request's body is still arriving;
- another request was read and has not been answered;
- input past the last request was already read and discarded;
- the parser holds bytes it has not used;
- the request was malformed, so where it ends is unknown.

If any of these holds, the close is **staged** (RFC 9112 §9.6):

1. The server shuts its write side, so the client reads the response and then end of file.
2. It reads and discards input until the client closes, or until the `early_response_drain` budget runs out (default `{infinity, 30000}`: no byte limit, 30 seconds).
3. It closes the socket.

Closing at once with unread input makes TCP send a reset, and a client that has not read the response yet can lose it.

To turn staging off, set the budget to `0`. The server then closes at once and may reset the connection mid-upload:

```erlang
{ok, _} = h1:start_server(8080, #{handler => fun my_app:handle/5,
                                  early_response_drain => 0}).
```

While a staged close drains, send calls return `{error, closed}`. Once the process has stopped, send calls exit (see `h1:send_response/4`).

## What you receive

Each close reports the reason it happened, whether it closed at once or was staged. A drain that ends on a timeout or on the byte budget does not change the reason.

| Close | Exit reason and `{closed, Reason}` | Handler or owner also gets |
| --- | --- | --- |
| Last response, by request, response, goaway or keep-alive limit | `{shutdown, goaway_sent}` | nothing |
| Early response | `{shutdown, early_close}` | nothing |
| Error response to a bad request | `{shutdown, Reason}`, the parse error | nothing |
| Server cancel | `{shutdown, stream_cancelled}` | `{stream_reset, StreamId, cancel}` |
| Client cancel | `normal`, as after `h1:close/1` | `{stream_reset, StreamId, cancel}`, then `{closed, normal}` |
| The peer leaves | `{shutdown, peer_closed}` | `{stream_reset, StreamId, peer_closed}` for a request in progress |

## When a handler fails

If your handler crashes, call `h1:internal_error/2` from the `catch`, as h1's own server loop does. It sends a 500 when no response was started. When a response was already started, it cancels it, so the client sees the response cut short instead of a completed one with error text in its body.

```erlang
try my_app:handle(Conn, Id, Method, Path, Headers)
catch _:_ -> h1:internal_error(Conn, Id)
end.
```

## Changing this code

- The close point is the `close_at` field in `h1_connection.erl`. `mark_last/2`, `served/2` and `cancel_due/1` set and read it.
- `server_close/5` is the only place that chooses between closing at once and staging. `input_pending/2` decides. `enter_lingering_close/3` runs the drain.
- Tests: `h1_close_SUITE` (last response), `h1_cancel_SUITE` (cancels, handler crashes, the reset during an upload), and the early-response cases in `h1_e2e_SUITE`.
- A regression test for a reset must drive a raw `gen_tcp` peer, and must read only after the reset could have arrived. Otherwise the client reads the bytes first and the test passes without the fix. `cancel_during_upload` in `h1_cancel_SUITE` shows the recipe.
