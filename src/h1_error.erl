%% @doc HTTP/1.1 error reason classification.
%%
%% H1 has no on-the-wire error code frame (unlike H2's RST_STREAM), so
%% this module normalises the reason atoms the parser, connection, and
%% encoder produce. Callers can map them to HTTP status codes or log
%% messages via `format/1'.
-module(h1_error).

-export([classify/1, format/1, status/1]).

-type parse_reason() :: bad_request
                      | line_too_long
                      | invalid_method
                      | invalid_uri
                      | invalid_version
                      | invalid_header_name
                      | invalid_header_value
                      | header_name_too_long
                      | header_value_too_long
                      | too_many_headers
                      | invalid_chunk_size
                      | chunk_size_too_long
                      | chunk_too_large
                      | invalid_chunk_terminator
                      | conflicting_framing
                      | body_too_large
                      | method_too_long
                      | uri_too_long.

-type conn_reason() :: request_timeout
                     | idle_timeout
                     | expect_timeout
                     | peer_closed
                     | upgrade_rejected
                     | keepalive_limit_reached
                     | pipeline_disabled
                     | goaway_sent.

-type reason() :: parse_reason() | conn_reason() | {closed, term()} | term().

-export_type([parse_reason/0, conn_reason/0, reason/0]).

%% @doc Coarse-grained classification for logging and handler dispatch.
-spec classify(reason()) -> parse_error | client_error | server_error
                          | timeout | closed | other.
classify(bad_request)              -> parse_error;
classify(line_too_long)            -> parse_error;
classify(invalid_method)           -> parse_error;
classify(invalid_uri)              -> parse_error;
classify(invalid_version)          -> parse_error;
classify(invalid_header_name)      -> parse_error;
classify(invalid_header_value)     -> parse_error;
classify(header_name_too_long)     -> parse_error;
classify(header_value_too_long)    -> parse_error;
classify(too_many_headers)         -> parse_error;
classify(invalid_chunk_size)       -> parse_error;
classify(chunk_size_too_long)      -> parse_error;
classify(chunk_too_large)          -> parse_error;
classify(invalid_chunk_terminator) -> parse_error;
classify(conflicting_framing)      -> parse_error;
classify(body_too_large)           -> client_error;
classify(method_too_long)          -> client_error;
classify(uri_too_long)             -> client_error;
classify(request_timeout)          -> timeout;
classify(idle_timeout)             -> timeout;
classify(expect_timeout)           -> timeout;
classify(peer_closed)              -> closed;
classify({closed, _})              -> closed;
classify(upgrade_rejected)         -> server_error;
classify(keepalive_limit_reached)  -> closed;
classify(pipeline_disabled)        -> client_error;
classify(goaway_sent)              -> closed;
classify(_)                        -> other.

%% @doc Suggested HTTP status code for a given error reason (server side).
-spec status(reason()) -> 400..599.
status(bad_request)              -> 400;
status(line_too_long)            -> 431;
status(invalid_method)           -> 400;
status(invalid_uri)              -> 400;
status(invalid_version)          -> 505;
status(invalid_header_name)      -> 400;
status(invalid_header_value)     -> 400;
status(header_name_too_long)     -> 431;
status(header_value_too_long)    -> 431;
status(too_many_headers)         -> 431;
status(invalid_chunk_size)       -> 400;
status(chunk_size_too_long)      -> 400;
status(chunk_too_large)          -> 413;
status(invalid_chunk_terminator) -> 400;
status(conflicting_framing)      -> 400;
status(body_too_large)           -> 413;
status(method_too_long)          -> 400;
status(uri_too_long)             -> 414;
status(request_timeout)          -> 408;
status(idle_timeout)             -> 408;
status(expect_timeout)           -> 417;
status(upgrade_rejected)         -> 426;
status(_)                        -> 500.

%% @doc Human-readable description of an error reason.
-spec format(reason()) -> string().
format(bad_request)              -> "Malformed HTTP message";
format(line_too_long)            -> "Request or status line exceeds configured limit";
format(invalid_method)           -> "Method token contains invalid characters";
format(invalid_uri)              -> "Request URI contains invalid characters";
format(invalid_version)          -> "Unsupported or malformed HTTP version";
format(invalid_header_name)      -> "Header name contains invalid characters";
format(invalid_header_value)     -> "Header value contains invalid characters";
format(header_name_too_long)     -> "Header name exceeds configured limit";
format(header_value_too_long)    -> "Header value exceeds configured limit";
format(too_many_headers)         -> "Message contains too many headers";
format(invalid_chunk_size)       -> "Chunk size is not valid hex";
format(chunk_size_too_long)      -> "Chunk size line exceeds 16 characters";
format(chunk_too_large)          -> "Chunk exceeds configured maximum size";
format(invalid_chunk_terminator) -> "Chunk not terminated with CRLF";
format(conflicting_framing)      -> "Both Content-Length and Transfer-Encoding present";
format(body_too_large)           -> "Body exceeds configured maximum size";
format(method_too_long)          -> "Method token exceeds configured limit";
format(uri_too_long)             -> "Request URI exceeds configured limit";
format(request_timeout)          -> "Timed out waiting for request";
format(idle_timeout)             -> "Connection idle for too long";
format(expect_timeout)           -> "No 100 Continue received within timeout";
format(peer_closed)              -> "Peer closed the connection";
format({closed, Reason})         -> "Connection closed: " ++ io_lib:format("~p", [Reason]);
format(upgrade_rejected)         -> "Requested Upgrade was rejected";
format(keepalive_limit_reached)  -> "Keep-alive request limit reached";
format(pipeline_disabled)        -> "Pipelining is disabled on this connection";
format(goaway_sent)              -> "Connection graceful shutdown in progress";
format(Other)                    -> io_lib:format("~p", [Other]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

classify_test_() ->
    [
        ?_assertEqual(parse_error, classify(bad_request)),
        ?_assertEqual(timeout,     classify(request_timeout)),
        ?_assertEqual(closed,      classify({closed, normal})),
        ?_assertEqual(other,       classify({whatever, x}))
    ].

status_test_() ->
    [
        ?_assertEqual(400, status(bad_request)),
        ?_assertEqual(431, status(line_too_long)),
        ?_assertEqual(413, status(body_too_large)),
        ?_assertEqual(500, status({something, other}))
    ].

-endif.
