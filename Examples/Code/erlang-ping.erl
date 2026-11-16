-module(ping).
-export([start/0, loop/1]).

%% Replies to {ping, From} with pong, counting messages.
start() -> spawn(?MODULE, loop, [0]).

loop(Count) ->
    receive
        {ping, From} ->
            From ! {pong, Count + 1},
            loop(Count + 1);
        stop ->
            io:format("stopped after ~p pings~n", [Count])
    end.
