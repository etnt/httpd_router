%%%-------------------------------------------------------------------
%%% @doc Supervisor for the httpd_router application.
%%%
%%% Supervises the {@link httpd_router_server} process which manages
%%% route table ETS tables.
%%% @end
%%%-------------------------------------------------------------------
-module(httpd_router_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% @private
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
init([]) ->
    Children = [
        #{id => httpd_router_server,
          start => {httpd_router_server, start_link, []},
          restart => permanent,
          type => worker}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
