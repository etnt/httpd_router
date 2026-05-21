%%%-------------------------------------------------------------------
%%% @doc Application behaviour for httpd_router.
%%%
%%% This module implements the OTP application behaviour. It starts
%%% the `httpd_router' supervisor tree which manages the route table
%%% server process.
%%% @end
%%%-------------------------------------------------------------------
-module(httpd_router_app).
-behaviour(application).

-export([start/2, stop/1]).

%% @private
start(_StartType, _StartArgs) ->
    httpd_router_sup:start_link().

%% @private
stop(_State) ->
    ok.
