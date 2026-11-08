---
name: protocol-change-review
description: "Use when changing, reviewing, or releasing erlang_h1 code that implements HTTP/1.1: the request/response/chunk parser, the message encoder, the connection state machine, pipelining, Expect: 100-continue, Upgrade/101 and CONNECT socket handoff, the RFC 9297 capsule codec, or listener/acceptor socket handling. Runs three checks before the change is called done: (1) compliance against RFC 9110/9112 and the project's suites, (2) the latest related specification, (3) safety against known HTTP/1.1 abuse classes. Trigger on edits to h1_parse_erl, h1_message, h1_connection, h1_server, h1_acceptor, h1_listener, h1_capsule, and before any release or PR."
---

# Protocol change review

A change to a protocol implementation is not done when the code compiles and the
happy path works. A wire protocol has three further obligations: it must match
the spec, it must match the *current* spec, and it must survive a hostile peer.
Run all three before calling the change done, opening the PR, or releasing.

Apply this to the parser, the encoder, the connection state machine, socket
handoff, and listener/acceptor code. When in doubt whether it applies, it
applies.

## 1. Compliance

Confirm the change still conforms, and that new behaviour is backed by a test.

- Run every check in `AGENTS.md`: `rebar3 eunit`, `rebar3 ct`, `rebar3 xref`,
  `rebar3 dialyzer`. The suites that matter most for wire behaviour are
  `h1_compliance_SUITE` (RFC rules), `h1_e2e_SUITE` (real client and server over
  TCP and TLS), `h1_handover_SUITE` (socket handoff), the in-module parser tests
  in `h1_parse_erl`, and `h1_prop_tests`.
- `h1_interop_SUITE` runs against curl, python `http.server` and nginx. Run the
  peers in Docker containers rather than installing them on the host. Say in
  the PR whether interop ran or was skipped.
- When a reviewer needs proof a test is real, run it against a clean baseline
  from a `git worktree` at the merge base (not `git stash`), so a new test is
  shown failing before the fix and passing after.
- Every spec rule the code enforces should cite its section (e.g. `RFC 9112
  §6.1`). When you add or change enforcement, add a test that exercises both
  the accept and the reject path.
- Parser bugs often depend on where a socket segment ends (a chunk-size line
  split between CR and LF, a header block split mid-line). Test the split with a
  raw `gen_tcp` peer that sends the pieces separately with a pause between
  them, and in the parser by feeding every split point of the input.
- Keep changes additive and opt-in where the project expects backward
  compatibility: existing suites stay green with zero edits.

## 2. Latest related specification

The spec the code cites may be superseded or revised. Check before trusting it.

- HTTP/1.1 is **RFC 9112** (message syntax) and **RFC 9110** (semantics), which
  obsolete RFC 7230-7235. Code or comments citing RFC 7230 should be checked
  against the current section. Capsules are **RFC 9297**; CONNECT-UDP (used by
  masque on top of h1) is **RFC 9298**; the varint is **RFC 9000 §16**.
- Use web search / the IETF datatracker to confirm you have the latest, look for
  errata on the RFC, and read the specific section; don't answer from memory.
  Note the exact version and date you checked in the PR or commit.
- When implementing an extension carried over HTTP/1.1 (Upgrade tokens, capsule
  types, CONNECT variants), verify the token names, capsule type values and
  status codes against the current draft or registry; these drift between
  revisions.
- If the latest spec disagrees with the code, treat the gap as part of the change
  (fix it, or call it out explicitly as deliberately out of scope).

## 3. Safety

An HTTP server is reachable by untrusted peers, and an HTTP client reads
untrusted responses. Review the change against the known abuse classes, and
bound every per-peer resource.

- Walk the HTTP/1.1 abuse classes and check the change neither introduces nor
  reopens one:
  - **Request smuggling / desync** (RFC 9112 §6.1, §6.3): both
    `Content-Length` and `Transfer-Encoding`, duplicate or conflicting
    `Content-Length`, `Transfer-Encoding` where chunked is not last, obs-fold or
    whitespace before the colon, bare CR or LF as line terminators, invalid
    characters in names and values. Reject; never guess.
  - **Chunked framing**: chunk-size overflow or overlong hex, chunk extensions
    without a bound, trailer fields that must not appear in trailers.
  - **Slowloris and slow body**: idle and request timers must fire while a peer
    trickles bytes; a slow upload must not hold a connection forever.
  - **Oversized input**: request line, header line, header count, header block
    and body each have a cap (`include/h1.hrl`), checked before buffering the
    whole thing.
  - **Pipelining**: a flood of pipelined requests must not queue responses or
    buffered requests without limit.
  - **Socket handoff** (Upgrade, CONNECT, `serve_socket/2`, the listen socket):
    no byte or close event may be lost or left in the wrong mailbox, and no
    socket may stay tied to a process that can exit.
  - **Early responses**: answering before the body is read must close cleanly
    within the drain budget, not reset the connection or read without bound.
  - **Client side**: response splitting through header values the caller
    passes in, unbounded response bodies, and TLS defaults (`verify_peer`,
    hostname check) staying on.
- Every per-peer structure needs a bound: buffered bytes, header count and size,
  pending pipelined requests, tracked connections, time spent waiting. A peer
  must not be able to grow any of them without limit.
- When the change fixes a real vulnerability: add a regression test that drives
  the attack over a raw socket and asserts the bound holds, write a CHANGELOG
  entry under a `Security` heading, and publish a GitHub Security Advisory
  (`gh api -X POST repos/benoitc/erlang_h1/security-advisories ...`, then
  `PATCH ... state=published`) referencing the CVE. GitHub as CNA can assign one.
- Do not weaken a limit to make a legitimate client pass; instead exclude the
  legitimate case precisely.

## Output

State the result of each of the three checks in the PR description or the
hand-off: which suites ran and passed, which spec version was checked, and which
abuse classes were considered. If one check was skipped, say so and why.
