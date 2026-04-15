%% h1.hrl - HTTP/1.1 library common definitions

-ifndef(H1_HRL).
-define(H1_HRL, 1).

%% ----------------------------------------------------------------------------
%% Default parser limits
%% ----------------------------------------------------------------------------
-define(H1_MAX_METHOD_SIZE,       16).
-define(H1_MAX_URI_SIZE,          8192).
-define(H1_MAX_HEADER_NAME_SIZE,  256).
-define(H1_MAX_HEADER_VALUE_SIZE, 8192).
-define(H1_MAX_HEADERS,           100).
-define(H1_MAX_CHUNK_SIZE,        1048576).   %% 1 MB
-define(H1_MAX_BODY_SIZE,         8388608).   %% 8 MB
-define(H1_MAX_LINE_LENGTH,       16384).     %% hackney default
-define(H1_MAX_EMPTY_LINES,       10).

%% ----------------------------------------------------------------------------
%% HTTP versions
%% ----------------------------------------------------------------------------
-define(HTTP_1_0, {1, 0}).
-define(HTTP_1_1, {1, 1}).

%% ----------------------------------------------------------------------------
%% Parser state record
%%
%% Streaming dual-mode parser (server + client). Feed bytes via
%% h1_parse_erl:execute/2 and consume events one at a time.
%% ----------------------------------------------------------------------------
-record(h1_parser, {
    %% Mode
    type             = auto :: auto | request | response,
    %% Current phase
    state            = on_first_line :: on_first_line | on_header | on_body
                                      | on_trailers | on_junk | done,
    %% Unconsumed input
    buffer           = <<>> :: binary(),
    %% Parsed metadata
    version          = undefined :: undefined | {non_neg_integer(), non_neg_integer()},
    method           = undefined :: undefined | binary(),
    partial_headers  = []        :: [{binary(), binary()}],
    %% Fast-path header values (lowercased where noted)
    clen             = undefined :: undefined | non_neg_integer() | bad_int,
    te               = undefined :: undefined | binary(),   %% lowercased
    connection       = undefined :: undefined | binary(),   %% lowercased
    ctype            = undefined :: undefined | binary(),   %% lowercased
    location         = undefined :: undefined | binary(),
    content_encoding = undefined :: undefined | binary(),   %% lowercased
    upgrade          = undefined :: undefined | binary(),   %% lowercased
    expect           = undefined :: undefined | binary(),   %% lowercased
    %% Body decoder state
    body_state       = waiting :: waiting | done
                                | {stream, fun(), term(), fun()},
    %% Limits
    max_line_length  = ?H1_MAX_LINE_LENGTH   :: pos_integer(),
    max_empty_lines  = ?H1_MAX_EMPTY_LINES   :: non_neg_integer(),
    max_header_name_size  = ?H1_MAX_HEADER_NAME_SIZE  :: pos_integer(),
    max_header_value_size = ?H1_MAX_HEADER_VALUE_SIZE :: pos_integer(),
    max_headers      = ?H1_MAX_HEADERS       :: pos_integer(),
    %% Counters
    empty_lines      = 0       :: non_neg_integer(),
    header_count     = 0       :: non_neg_integer()
}).

-endif.
