-module(crud_api).
-export([start/0, start/1, stop/0]).
-export([handle_users/1, auth_check/1]).

-define(DEFAULT_PORT, 8080).

%% @doc Start the CRUD API on the default port (8080).
start() ->
    start(?DEFAULT_PORT).

%% @doc Start the CRUD API on a given port.
start(Port) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(httpd_router),

    %% Create a per-port route table
    TableName = httpd_router:mk_table_name({127, 0, 0, 1}, Port),
    {ok, _} = httpd_router:start(TableName),

    %% CRUD route: automatically creates GET, POST, PUT, PATCH, DELETE routes
    httpd_router:table_add_route(
        TableName,
        "CRUD",
        "/api/users",
        fun crud_api:handle_users/1,
        [fun crud_api:auth_check/1]
    ),

    %% Start httpd
    DocRoot = "/tmp/crud_api",
    filelib:ensure_dir(DocRoot ++ "/x"),
    {ok, _Pid} = inets:start(httpd, [
        {port, Port},
        {server_name, "crud_api"},
        {server_root, "/tmp"},
        {document_root, DocRoot},
        {bind_address, {127, 0, 0, 1}},
        {socket_type, {ip_comm, [{nodelay, true}]}},
        {modules, [httpd_router]},
        {httpd_router_table, TableName}
    ]),
    io:format("CRUD API started on http://127.0.0.1:~p/~n", [Port]),
    io:format("Try:~n"),
    io:format("  curl http://127.0.0.1:~p/api/users~n", [Port]),
    io:format("  curl http://127.0.0.1:~p/api/users/42~n", [Port]),
    io:format(
        "  curl -is -X POST -H 'Content-Type: application/json' -d '{\"name\":\"Lisa\"}' http://127.0.0.1:~p/api/users~n",
        [Port]
    ),
    io:format("  curl -X DELETE http://127.0.0.1:~p/api/users/42~n", [Port]),
    io:format("  curl -X OPTIONS http://127.0.0.1:~p/api/users~n", [Port]),
    ok.

%% @doc Stop the API server.
stop() ->
    inets:stop(),
    application:stop(httpd_router).

%%--------------------------------------------------------------------
%% Middleware: simple auth check (accepts everything for demo)
%%--------------------------------------------------------------------

auth_check(Ctx) ->
    %% In a real app, check Authorization header here
    {ok, Ctx#{opaque => #{authenticated => true}}}.

%%--------------------------------------------------------------------
%% CRUD handler — dispatches on `action` key in Ctx
%%--------------------------------------------------------------------

handle_users(#{action := index}) ->
    Users = [
        #{id => <<"1">>, name => <<"Alice">>},
        #{id => <<"2">>, name => <<"Bob">>}
    ],
    {json, 200, #{users => Users}};
handle_users(#{action := show, params := #{id := Id}}) ->
    {json, 200, #{
        id => list_to_binary(Id),
        name => <<"User ", (list_to_binary(Id))/binary>>
    }};
handle_users(#{action := create, body := Body, path := Path}) ->
    %% Parse incoming JSON body
    User =
        case Body of
            <<>> -> #{};
            _ -> json:decode(Body)
        end,
    %% Simulate generating a new ID
    NewId = integer_to_binary(erlang:unique_integer([positive]) rem 10000),
    Name = maps:get(<<"name">>, User, <<"Anonymous">>),
    Location = iolist_to_binary([Path, "/", NewId]),
    {json, 201, [{"location", binary_to_list(Location)}], #{
        id => NewId, name => Name, status => <<"created">>
    }};
handle_users(#{action := replace, params := #{id := Id}}) ->
    {json, 200, #{id => list_to_binary(Id), status => <<"replaced">>}};
handle_users(#{action := modify, params := #{id := Id}}) ->
    {json, 200, #{id => list_to_binary(Id), status => <<"modified">>}};
handle_users(#{action := delete, params := #{id := Id}}) ->
    {json, 200, #{id => list_to_binary(Id), status => <<"deleted">>}};
handle_users(_Ctx) ->
    {json, 405, #{error => <<"Method not allowed">>}}.
