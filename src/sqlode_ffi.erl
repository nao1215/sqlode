%% Erlang FFI helpers for sqlode.
%%
%% These shims bridge Gleam to BEAM primitives that have no portable
%% Gleam stdlib equivalent. Keep this file small — every function here
%% should be a thin wrapper that returns a value Gleam already has a
%% type for.
-module(sqlode_ffi).

-export([is_stdout_terminal/0, no_color_env/0]).

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
