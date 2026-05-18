%% Erlang FFI helpers for sqlode.
%%
%% These shims bridge Gleam to BEAM primitives that have no portable
%% Gleam stdlib equivalent. Keep this file small — every function here
%% should be a thin wrapper that returns a value Gleam already has a
%% type for.
-module(sqlode_ffi).

-export([is_stdout_terminal/0, no_color_env/0, find_executable/1, run_executable/2]).

%% Returns true iff `standard_io` is connected to an interactive
%% terminal. When stdout is redirected to a file or pipe (as in
%% `sqlode --help > file.txt` or `sqlode --help | less`), the
%% `terminal` opt is missing or false. Matches the convention CLI
%% colorizers use for `isatty(1)` detection.
is_stdout_terminal() ->
    case io:getopts(standard_io) of
        Opts when is_list(Opts) ->
            proplists:get_value(terminal, Opts, false) =:= true;
        _ ->
            false
    end.

%% Returns `{ok, Value}` (as a Gleam-friendly tagged tuple) when the
%% NO_COLOR environment variable is set to a non-empty string, and
%% `{error, nil}` otherwise. Per https://no-color.org/, the variable
%% being present and non-empty (regardless of value) means "do not
%% emit colour".
no_color_env() ->
    case os:getenv("NO_COLOR") of
        false ->
            {error, nil};
        "" ->
            {error, nil};
        Value ->
            {ok, list_to_binary(Value)}
    end.

%% Locate an executable on `PATH`. Returns `{ok, Path}` (binary) on
%% success or `{error, nil}` when no match is found, matching the
%% Gleam `Result(String, Nil)` shape. Used by the codegen formatter
%% step to find the `gleam` binary before invoking `gleam format`.
-spec find_executable(binary()) -> {ok, binary()} | {error, nil}.
find_executable(Name) ->
    case os:find_executable(binary_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, list_to_binary(Path)}
    end.

%% Run an executable with the given list of arguments and capture its
%% combined stdout+stderr. Returns `{ExitCode, Output}` so callers can
%% surface `gleam format`'s diagnostic output verbatim when the run
%% fails — exit code alone is opaque if a generated file has a syntax
%% error. Uses `spawn_executable` (no shell) to avoid argument-quoting
%% pitfalls. The hard 60s timeout protects the CLI from a hung
%% formatter; a large generated tree finishes well under that.
-spec run_executable(binary(), list(binary())) -> {integer(), binary()}.
run_executable(Executable, Args) ->
    Port = open_port(
        {spawn_executable, binary_to_list(Executable)},
        [exit_status, stderr_to_stdout, binary, {args, [binary_to_list(A) || A <- Args]}]
    ),
    collect_exit(Port, <<>>).

collect_exit(Port, Acc) ->
    receive
        {Port, {data, Chunk}} when is_binary(Chunk) ->
            collect_exit(Port, <<Acc/binary, Chunk/binary>>);
        {Port, {exit_status, Code}} ->
            {Code, Acc}
    after 60000 ->
        try port_close(Port) catch _:_ -> ok end,
        {1, <<Acc/binary, "(timed out after 60s)">>}
    end.
