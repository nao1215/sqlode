-module(runtime_test_ffi).
-export([rescue/1]).

rescue(F) ->
    try F() of
        _ -> {ok, nil}
    catch
        error:_ -> {error, nil}
    end.
