# Agents

Instructions for AI coding agents working on this project.

## Project Overview

Pure Erlang HTTP/1.1 implementation (RFC 9110 / RFC 9112) with zero external
runtime dependencies: client, server, chunked transfer and trailers, pipelining,
`Expect: 100-continue`, Upgrade / 101 and CONNECT with socket handoff, and the
RFC 9297 capsule codec. The API mirrors `h2` (HTTP/2) and `quic_h3` (HTTP/3) so
call sites can swap protocols. Requires Erlang/OTP 27+ and rebar3.

## Required Checks

Every change must compile and pass all checks before committing. This matches
what CI gates on (`.github/workflows/ci.yml`, OTP 27, 28 and 29).

```bash
rebar3 compile              # Must compile cleanly (warnings are errors)
rebar3 eunit                # In-module tests + PropEr properties
rebar3 ct                   # Common Test: e2e, compliance, handover, interop, ranch
rebar3 xref                 # Cross-reference analysis must pass
rebar3 dialyzer             # Type checking must pass
rebar3 ex_doc               # Docs must build
```

`h1_interop_SUITE` drives curl, python `http.server` and nginx. Each case skips
when its tool is absent. Run the peers in Docker containers; do not install them
on the host with `brew`.

## Protocol change review

A change to protocol code is not done when it compiles and the happy path works.
Before calling a change done, opening a pull request, or releasing, run the three
checks in the [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
skill and state their result in the pull request:

1. **Compliance**: the suites above pass; cite the spec section (e.g. `RFC 9112
   §6.1`) for each rule enforced; add both an accept and a reject test; prove a
   new test against a `git worktree` baseline at the merge base, not `git stash`.
2. **Latest related specification**: confirm the governing RFC/draft is current
   via the IETF datatracker; read the section, note the version and date checked.
3. **Safety**: check the change against the known HTTP/1.1 abuse classes
   (request smuggling, slowloris, oversized lines and header blocks, chunk-size
   overflow, pipelining floods, handover data loss) and keep every per-peer
   resource bounded. On a real vulnerability fix add a raw-socket regression
   test, a `Security` CHANGELOG entry, and a published GitHub Security Advisory.

## Pull Requests

Never commit or push directly to `main`. Every change goes on a branch and
through a pull request for review. Release tags, GitHub releases and hex
publishes happen only after the pull request is merged.

Work on one issue goes in one pull request. Docs and CHANGELOG entries go in the
same pull request. Keep the description to the intent and the fix in a few lines
plus any breaking changes; do not walk the diff file by file, and do not add a
test-plan section. CHANGELOG entries and release notes are short, plain English:
what was wrong or new and what it means for the user, with no code snippets or
internal detail. Commit messages describe the change, with no milestone prefixes.

## Releases

After the release pull request is merged:

1. The CHANGELOG section, `{vsn, ...}` in `src/h1.app.src`, and both version pins
   in `README.md` (hex dep and git `{tag, ...}`) all name the new version.
2. Tag the merge commit with the bare version (`git tag -a 0.9.3`, no `v`
   prefix) and push the tag.
3. `gh release create <vsn>` with the CHANGELOG section as notes, as is.
4. `rebar3 hex publish`.

## Skills

Task guides for agents live in `.agents/skills/<name>/SKILL.md`; read the one
that matches the task before starting. `.claude/skills` links to the same
directories, so there is one copy.

- [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md): check
  a change or pull request for compliance, the latest related spec, and safety.

## Build & Development Commands

```bash
rebar3 compile                                       # Build
rebar3 eunit                                         # Run all EUnit tests
rebar3 eunit --module=h1_parse_erl                   # Run one module's tests
rebar3 eunit --module=h1_prop_tests                  # PropEr properties
rebar3 ct                                            # Run all Common Test suites
rebar3 ct --suite=test/h1_e2e_SUITE                  # Run one suite
rebar3 xref                                          # Cross-reference analysis
rebar3 dialyzer                                      # Type checking
rebar3 ex_doc                                        # Generate docs under doc/
```

## Architecture

### Module Layers

**Public API:** `h1.erl` (client + server API), `h1_client.erl` (connect
helpers)

**Server:** `h1_listener.erl` (owns the listen socket, the acceptor pool and the
set of accepted connections), `h1_acceptor.erl` (accept loop),
`h1_server.erl` (per-connection loop: TLS handshake, then runs an
`h1_connection`), `h1_sup.erl` / `h1_app.erl` (OTP app and supervisor)

**Connection:** `h1_connection.erl` (gen_statem, the central module; owns one
socket in client or server mode, drives the parser, handles pipelining,
Upgrade and CONNECT handoff)

**Protocol:** `h1_parse.erl` (parser facade) over `h1_parse_erl.erl` (pure
Erlang request/response/chunk parser), `h1_message.erl` (encoder),
`h1_error.erl` (error classification), `h1_upgrade.erl` (post-Upgrade helpers),
`h1_capsule.erl` + `h1_varint.erl` (RFC 9297 capsules)

### Supervision Tree

`h1_app` → `h1_sup` (`simple_one_for_one` over `h1_listener`). Each server is a
listener child; it owns the listen socket, links its acceptors, and tracks every
accepted connection so `h1:stop_server/1` can close them. Connections served
with `h1:serve_socket/2` are linked to the caller and belong to no listener.

### Connection Model

The owner process receives `{h1, Conn, Event}` messages: `{response, StreamId,
Status, Headers}`, `{data, StreamId, Data, Fin}`, `{trailers, StreamId,
Trailers}`, `{closed, Reason}`. A server handler is called as
`Handler(Conn, StreamId, Method, Path, Headers)` and answers with
`h1:respond/5,6` or `h1:send_response/4` + `h1:send_data/3,4`. Socket ownership
moves by `controlling_process`; any code that hands a socket to another process
must not lose bytes or close events queued in the mailbox.

### Key Files

- `include/h1.hrl`: shared records, defaults and limits
- `docs/features.md`: feature matrix and API reference
- `docs/ranch.md`: running h1 under Ranch
- `README.md`: usage and examples

### Test Organization

- Internals are tested in-module under `-ifdef(TEST)` (`h1_parse_erl`,
  `h1_capsule`, `h1_varint`, `h1_error`)
- `test/h1_prop_tests.erl`: PropEr properties (encode/decode roundtrips, and
  bodyless response framing, run from `h1_bodyless_SUITE`)
- `test/h1_*_SUITE.erl`: Common Test. `h1_e2e_SUITE` (real client and server
  over TCP and TLS), `h1_compliance_SUITE` (RFC 9110/9112 rules),
  `h1_handover_SUITE` (bytes and close events across socket handoff),
  `h1_listener_owner_SUITE` (a server outlives the process that started it),
  `h1_peercert_SUITE` (TLS peer certificate),
  `h1_bodyless_SUITE` (HEAD / 1xx / 204 / 304 framing on both sides),
  `h1_close_SUITE` (pipelined and handler `Connection: close`, trailers),
  `h1_flow_control_SUITE` (`flow_control => manual` and `consume/3`),
  `h1_connect_SUITE`, `h1_upgrade_SUITE`, `h1_serve_socket_SUITE`,
  `h1_ranch_SUITE` (with `h1_ranch_protocol`), `h1_interop_SUITE`
- Regression tests for wire bugs drive a raw `gen_tcp` peer and assert exact
  bytes; when a bug depends on segment boundaries, send the pieces separately
  with a pause between them
