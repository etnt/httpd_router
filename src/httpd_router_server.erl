%%%-------------------------------------------------------------------
%%% @doc Route table management server for httpd_router.
%%%
%%% This `gen_server' manages ETS tables that store route definitions.
%%% It handles table creation, route insertion (including CRUD
%%% expansion), and table option management.
%%%
%%% This module is internal to the `httpd_router' application. Use
%%% the public API in {@link httpd_router} instead of calling this
%%% module directly.
%%% @end
%%%-------------------------------------------------------------------
-module(httpd_router_server).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    create_table/1,
    create_table/2,
    add_route/5,
    get_tables/0,
    get_options/1,
    set_option/3
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-include("httpd_router.hrl").

-record(state, {
    %% [{TableName, Options}]
    tables = [] :: [{atom(), map()}]
}).

-define(DEFAULT_OPTIONS, #{no_match => 404}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start the route table server and link to the calling process.
%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Create a route table with default options.
%% @see create_table/2
create_table(TableName) ->
    create_table(TableName, ?DEFAULT_OPTIONS).

%% @doc Create a named route table with the given options.
%%
%% Options:
%% <ul>
%%   <li>`no_match' - `404 | passthrough' (default: `404')</li>
%% </ul>
%% @end
create_table(TableName, Options) when is_atom(TableName), is_map(Options) ->
    gen_server:call(?MODULE, {create_table, TableName, Options}).

%% @doc Add a route to the named table.
%%
%% If `Method' is a CRUD string (e.g. `"CRUD"', `"CR"'), it is
%% expanded into multiple routes automatically.
%% @end
add_route(TableName, Method, PathPattern, Handler, Middlewares) when
    is_atom(TableName),
    is_list(Method),
    is_list(PathPattern),
    is_function(Handler, 1),
    is_list(Middlewares)
->
    gen_server:call(
        ?MODULE,
        {add_route, TableName, Method, PathPattern, Handler, Middlewares}
    ).

%% @doc Return all registered tables and their options.
get_tables() ->
    gen_server:call(?MODULE, get_tables).

%% @doc Get the options map for a named table.
get_options(TableName) ->
    gen_server:call(?MODULE, {get_options, TableName}).

%% @doc Set a single option on a named table.
set_option(TableName, Key, Value) ->
    gen_server:call(?MODULE, {set_option, TableName, Key, Value}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

handle_call(
    {create_table, TableName, Options}, _From, #state{tables = Tables} = State
) ->
    case lists:keyfind(TableName, 1, Tables) of
        false ->
            ets:new(TableName, [
                named_table, protected, bag, {keypos, #route.key}
            ]),
            {reply, {ok, TableName}, State#state{
                tables = [{TableName, Options} | Tables]
            }};
        _ ->
            {reply, {ok, TableName}, State}
    end;
handle_call(
    {add_route, TableName, Method, PathPattern, Handler, Middlewares},
    _From,
    State
) ->
    case is_crud(Method) of
        true ->
            add_crud_routes(
                TableName, Method, PathPattern, Handler, Middlewares
            ),
            {reply, ok, State};
        false ->
            insert_route(
                TableName,
                Method,
                PathPattern,
                Handler,
                Middlewares,
                undefined,
                undefined
            ),
            {reply, ok, State}
    end;
handle_call(get_tables, _From, #state{tables = Tables} = State) ->
    {reply, {ok, Tables}, State};
handle_call({get_options, TableName}, _From, #state{tables = Tables} = State) ->
    case lists:keyfind(TableName, 1, Tables) of
        {TableName, Options} -> {reply, {ok, Options}, State};
        false -> {reply, {error, no_such_table}, State}
    end;
handle_call(
    {set_option, TableName, Key, Value}, _From, #state{tables = Tables} = State
) ->
    case lists:keyfind(TableName, 1, Tables) of
        {TableName, Options} ->
            NewOptions = Options#{Key => Value},
            NewTables = lists:keyreplace(
                TableName, 1, Tables, {TableName, NewOptions}
            ),
            {reply, ok, State#state{tables = NewTables}};
        false ->
            {reply, {error, no_such_table}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

insert_route(
    TableName, Method, PathPattern, Handler, Middlewares, Crud, Action
) ->
    Route = #route{
        key = {Method, PathPattern},
        method = Method,
        path_pattern = PathPattern,
        handler = Handler,
        middlewares = Middlewares,
        crud = Crud,
        action = Action,
        params = undefined
    },
    ets:insert(TableName, Route).

add_crud_routes(TableName, Crud, PathPattern, Handler, Middlewares) ->
    IdPattern = PathPattern ++ "/:id",
    lists:foreach(
        fun
            ($C) ->
                insert_route(
                    TableName,
                    "POST",
                    PathPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    create
                );
            ($R) ->
                insert_route(
                    TableName,
                    "GET",
                    PathPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    index
                ),
                insert_route(
                    TableName,
                    "GET",
                    IdPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    show
                );
            ($U) ->
                insert_route(
                    TableName,
                    "PUT",
                    IdPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    replace
                ),
                insert_route(
                    TableName,
                    "PATCH",
                    IdPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    modify
                );
            ($D) ->
                insert_route(
                    TableName,
                    "DELETE",
                    IdPattern,
                    Handler,
                    Middlewares,
                    Crud,
                    delete
                )
        end,
        Crud
    ),
    %% Add OPTIONS handler for CRUD routes (requires OTP patch for
    %% httpd_request:validate/3 to include "OPTIONS").
    insert_route(
        TableName, "OPTIONS", PathPattern, undefined, [], Crud, options
    ),
    insert_route(TableName, "OPTIONS", IdPattern, undefined, [], Crud, options).

is_crud(Method) ->
    lists:all(fun(C) -> lists:member(C, "CRUD") end, Method) andalso
        length(Method) > 0 andalso
        not lists:member(Method, [
            "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"
        ]).
