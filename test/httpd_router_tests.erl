-module(httpd_router_tests).
-include_lib("eunit/include/eunit.hrl").
-include("httpd_router.hrl").

%%--------------------------------------------------------------------
%% Test fixtures
%%--------------------------------------------------------------------

setup() ->
    application:ensure_all_started(httpd_router),
    ok.

cleanup(_) ->
    application:stop(httpd_router),
    ok.

%%--------------------------------------------------------------------
%% Path matching tests
%%--------------------------------------------------------------------

match_path_test_() ->
    [
        {"exact match",
            ?_assertEqual(
                {true, #{}}, httpd_router:match_path("/hello", "/hello")
            )},
        {"root match",
            ?_assertEqual({true, #{}}, httpd_router:match_path("/", "/"))},
        {"single param",
            ?_assertEqual(
                {true, #{id => "42"}},
                httpd_router:match_path("/users/:id", "/users/42")
            )},
        {"multiple params",
            ?_assertEqual(
                {true, #{org => "acme", id => "7"}},
                httpd_router:match_path(
                    "/orgs/:org/users/:id", "/orgs/acme/users/7"
                )
            )},
        {"no match - different length",
            ?_assertEqual(
                false, httpd_router:match_path("/users/:id", "/users/42/posts")
            )},
        {"no match - different segment",
            ?_assertEqual(
                false, httpd_router:match_path("/users/:id", "/posts/42")
            )},
        {"empty path no match",
            ?_assertEqual(false, httpd_router:match_path("/hello", ""))}
    ].

%%--------------------------------------------------------------------
%% Route registration and lookup tests
%%--------------------------------------------------------------------

route_registration_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"add and find simple route", fun() ->
                TableName = test_routes_simple,
                {ok, _} = httpd_router_server:create_table(TableName),
                Handler = fun(_Ctx) -> {status, 200} end,
                ok = httpd_router_server:add_route(
                    TableName, "GET", "/hello", Handler, []
                ),
                {ok, Route} = httpd_router:find_route(
                    "GET", "/hello", TableName
                ),
                ?assertEqual("GET", Route#route.method),
                ?assertEqual("/hello", Route#route.path_pattern),
                ?assertEqual(Handler, Route#route.handler)
            end},
            {"find route with params", fun() ->
                TableName = test_routes_params,
                {ok, _} = httpd_router_server:create_table(TableName),
                Handler = fun(_Ctx) -> {status, 200} end,
                ok = httpd_router_server:add_route(
                    TableName, "GET", "/users/:id", Handler, []
                ),
                {ok, Route} = httpd_router:find_route(
                    "GET", "/users/99", TableName
                ),
                ?assertEqual(#{id => "99"}, Route#route.params)
            end},
            {"not found returns not_found", fun() ->
                TableName = test_routes_notfound,
                {ok, _} = httpd_router_server:create_table(TableName),
                ?assertEqual(
                    not_found,
                    httpd_router:find_route("GET", "/nope", TableName)
                )
            end},
            {"method mismatch returns not_found", fun() ->
                TableName = test_routes_method,
                {ok, _} = httpd_router_server:create_table(TableName),
                Handler = fun(_Ctx) -> {status, 200} end,
                ok = httpd_router_server:add_route(
                    TableName, "POST", "/items", Handler, []
                ),
                ?assertEqual(
                    not_found,
                    httpd_router:find_route("GET", "/items", TableName)
                )
            end}
        ]
    end}.

%%--------------------------------------------------------------------
%% CRUD route expansion tests
%%--------------------------------------------------------------------

crud_expansion_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"CRUD expands to all methods", fun() ->
                TableName = test_routes_crud,
                {ok, _} = httpd_router_server:create_table(TableName),
                Handler = fun(_Ctx) -> {status, 200} end,
                ok = httpd_router_server:add_route(
                    TableName, "CRUD", "/items", Handler, []
                ),

                %% R -> GET /items (index) and GET /items/:id (show)
                {ok, R1} = httpd_router:find_route("GET", "/items", TableName),
                ?assertEqual(index, R1#route.action),
                {ok, R2} = httpd_router:find_route(
                    "GET", "/items/1", TableName
                ),
                ?assertEqual(show, R2#route.action),

                %% C -> POST /items (create)
                {ok, R3} = httpd_router:find_route("POST", "/items", TableName),
                ?assertEqual(create, R3#route.action),

                %% U -> PUT /items/:id (replace) and PATCH /items/:id (modify)
                {ok, R4} = httpd_router:find_route(
                    "PUT", "/items/1", TableName
                ),
                ?assertEqual(replace, R4#route.action),
                {ok, R5} = httpd_router:find_route(
                    "PATCH", "/items/1", TableName
                ),
                ?assertEqual(modify, R5#route.action),

                %% D -> DELETE /items/:id (delete)
                {ok, R6} = httpd_router:find_route(
                    "DELETE", "/items/1", TableName
                ),
                ?assertEqual(delete, R6#route.action)
            end},
            {"partial CRUD: CR only", fun() ->
                TableName = test_routes_cr,
                {ok, _} = httpd_router_server:create_table(TableName),
                Handler = fun(_Ctx) -> {status, 200} end,
                ok = httpd_router_server:add_route(
                    TableName, "CR", "/things", Handler, []
                ),

                {ok, _} = httpd_router:find_route("POST", "/things", TableName),
                {ok, _} = httpd_router:find_route("GET", "/things", TableName),
                {ok, _} = httpd_router:find_route(
                    "GET", "/things/1", TableName
                ),
                ?assertEqual(
                    not_found,
                    httpd_router:find_route("DELETE", "/things/1", TableName)
                ),
                ?assertEqual(
                    not_found,
                    httpd_router:find_route("PUT", "/things/1", TableName)
                )
            end}
        ]
    end}.

%%--------------------------------------------------------------------
%% Middleware tests
%%--------------------------------------------------------------------

middleware_test_() ->
    [
        {"middlewares execute in order", fun() ->
            M1 = fun(Ctx) -> {ok, Ctx#{step1 => done}} end,
            M2 = fun(Ctx) -> {ok, Ctx#{step2 => done}} end,
            {ok, Result} = httpd_router:execute_middlewares([M1, M2], #{
                opaque => #{}
            }),
            ?assertEqual(done, maps:get(step1, Result)),
            ?assertEqual(done, maps:get(step2, Result))
        end},
        {"middleware short-circuits on error", fun() ->
            M1 = fun(_Ctx) -> {error, {status, 401}} end,
            M2 = fun(Ctx) -> {ok, Ctx#{should_not_run => true}} end,
            Result = httpd_router:execute_middlewares([M1, M2], #{opaque => #{}}),
            ?assertEqual({error, {status, 401}}, Result)
        end},
        {"empty middleware list passes through", fun() ->
            Ctx = #{hello => world},
            ?assertEqual({ok, Ctx}, httpd_router:execute_middlewares([], Ctx))
        end}
    ].

%%--------------------------------------------------------------------
%% Full HTTP round-trip test
%%--------------------------------------------------------------------

http_roundtrip_test_() ->
    {setup,
        fun() ->
            application:ensure_all_started(inets),
            application:ensure_all_started(httpd_router),
            {ok, _} = httpd_router_server:create_table(httpd_roundtrip_routes),
            httpd_router:table_add_route(
                httpd_roundtrip_routes,
                "GET",
                "/test/hello",
                fun(_Ctx) -> {text, 200, "text/plain", "Hello!"} end,
                []
            ),
            httpd_router:table_add_route(
                httpd_roundtrip_routes,
                "GET",
                "/test/user/:id",
                fun(#{params := #{id := Id}}) ->
                    {json, 200, #{id => list_to_binary(Id)}}
                end,
                []
            ),
            DocRoot = "/tmp/httpd_router_test",
            filelib:ensure_dir(DocRoot ++ "/x"),
            {ok, Pid} = inets:start(httpd, [
                {port, 0},
                {server_name, "test_api"},
                {server_root, "/tmp"},
                {document_root, DocRoot},
                {bind_address, {127, 0, 0, 1}},
                {modules, [httpd_router]},
                {httpd_router_table, httpd_roundtrip_routes}
            ]),
            Info = httpd:info(Pid),
            Port = proplists:get_value(port, Info),
            {Pid, Port}
        end,
        fun({Pid, _Port}) ->
            inets:stop(httpd, Pid),
            application:stop(httpd_router)
        end,
        fun({_Pid, Port}) ->
            BaseUrl = "http://127.0.0.1:" ++ integer_to_list(Port),
            [
                {"GET /test/hello returns 200 with text body", fun() ->
                    {ok, {{_, 200, _}, _Headers, Body}} =
                        httpc:request(
                            get,
                            {BaseUrl ++ "/test/hello", []},
                            [{timeout, 2000}],
                            []
                        ),
                    ?assertEqual("Hello!", Body)
                end},
                {"GET /test/user/:id returns JSON with param", fun() ->
                    {ok, {{_, 200, _}, Headers, Body}} =
                        httpc:request(
                            get,
                            {BaseUrl ++ "/test/user/42", []},
                            [{timeout, 2000}],
                            []
                        ),
                    ?assertMatch(
                        "application/json" ++ _,
                        proplists:get_value("content-type", Headers)
                    ),
                    ?assert(string:find(Body, "\"id\"") =/= nomatch),
                    ?assert(string:find(Body, "\"42\"") =/= nomatch)
                end},
                {"GET unknown path returns 404", fun() ->
                    {ok, {{_, 404, _}, _Headers, _Body}} =
                        httpc:request(
                            get,
                            {BaseUrl ++ "/nonexistent", []},
                            [{timeout, 2000}],
                            []
                        )
                end}
            ]
        end}.

%%--------------------------------------------------------------------
%% Table options test
%%--------------------------------------------------------------------

options_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) ->
        [
            {"default option is no_match 404", fun() ->
                TableName = test_routes_opts,
                {ok, _} = httpd_router_server:create_table(TableName),
                {ok, Opts} = httpd_router_server:get_options(TableName),
                ?assertEqual(404, maps:get(no_match, Opts))
            end},
            {"can set no_match to passthrough", fun() ->
                TableName = test_routes_opts2,
                {ok, _} = httpd_router_server:create_table(TableName, #{
                    no_match => passthrough
                }),
                {ok, Opts} = httpd_router_server:get_options(TableName),
                ?assertEqual(passthrough, maps:get(no_match, Opts))
            end}
        ]
    end}.
