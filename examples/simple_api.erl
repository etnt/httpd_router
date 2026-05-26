-module(simple_api).
-export([start/0, start/1, stop/0]).
-export([
    root/1,
    hello/1,
    user/1
]).

-define(DEFAULT_PORT, 8080).

%% @doc Start the simple API on the default port (8080).
start() ->
    start(?DEFAULT_PORT).

%% @doc Start the simple API on a given port.
start(Port) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(httpd_router),

    %% Create a per-port route table
    TableName = httpd_router:mk_table_name({127, 0, 0, 1}, Port),
    {ok, _} = httpd_router:start(TableName),

    %% Register routes on this table
    httpd_router:table_add_route(
        TableName, "GET", "/", fun simple_api:root/1, []
    ),
    httpd_router:table_add_route(
        TableName, "GET", "/hello", fun simple_api:hello/1, []
    ),
    httpd_router:table_add_route(
        TableName, "GET", "/user/:id", fun simple_api:user/1, []
    ),

    %% Start httpd with httpd_router_table pointing to our table
    DocRoot = "/tmp/simple_api",
    filelib:ensure_dir(DocRoot ++ "/x"),
    {ok, _Pid} = inets:start(httpd, [
        {port, Port},
        {server_name, "simple_api"},
        {server_root, "/tmp"},
        {document_root, DocRoot},
        {bind_address, {127, 0, 0, 1}},
        {socket_type, {ip_comm, [{nodelay, true}]}},
        {modules, [httpd_router]},
        {httpd_router_table, TableName}
    ]),
    io:format("Simple API started on http://127.0.0.1:~p/~n", [Port]),
    io:format("Try:~n"),
    io:format("  curl http://127.0.0.1:~p/~n", [Port]),
    io:format("  curl http://127.0.0.1:~p/hello~n", [Port]),
    io:format("  curl http://127.0.0.1:~p/hello?name=Erlang~n", [Port]),
    io:format("  curl http://127.0.0.1:~p/user/42~n", [Port]),
    ok.

%% @doc Stop the API server.
stop() ->
    inets:stop(),
    application:stop(httpd_router).

%%--------------------------------------------------------------------
%% Route handlers
%%--------------------------------------------------------------------

root(_Ctx) ->
    {json, 200, #{message => <<"Welcome to the Simple API!">>}}.

hello(#{query := Query}) ->
    Name = maps:get(<<"name">>, Query, <<"world">>),
    Greeting = <<"Hello, ", Name/binary, "!">>,
    {json, 200, #{greeting => Greeting}}.

user(#{params := #{id := Id}}) ->
    {json, 200, #{
        id => list_to_binary(Id),
        name => <<"User ", (list_to_binary(Id))/binary>>
    }}.
