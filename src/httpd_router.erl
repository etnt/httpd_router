%%%-------------------------------------------------------------------
%%% @doc A declarative routing module for OTP's built-in httpd server.
%%%
%%% `httpd_router' implements the `do/1' callback expected by the
%%% `httpd' module pipeline, providing:
%%%
%%% <ul>
%%%   <li>Declarative route registration with path patterns
%%%       (e.g. `"/users/:id"').</li>
%%%   <li>Middleware chains for cross-cutting concerns (auth, logging,
%%%       CORS).</li>
%%%   <li>CRUD route shortcuts that expand a single registration into
%%%       GET, POST, PUT, PATCH, DELETE and OPTIONS routes.</li>
%%%   <li>Automatic OPTIONS/CORS preflight handling.</li>
%%%   <li>A clean request context map passed to handlers instead of
%%%       raw `#mod{}' records.</li>
%%%   <li>Multiple named route tables for different server
%%%       instances.</li>
%%% </ul>
%%%
%%% == Quick Start ==
%%%
%%% ```
%%% {ok, _} = application:ensure_all_started(inets),
%%% {ok, _} = application:ensure_all_started(httpd_router),
%%% {ok, _} = httpd_router:start(),
%%% httpd_router:add_route("GET", "/hello", fun my_handler:hello/1),
%%% httpd_router:add_route("GET", "/user/:id", fun my_handler:user/1),
%%% {ok, _} = inets:start(httpd, [
%%%     {port, 8080},
%%%     {server_name, "my_api"},
%%%     {server_root, "/tmp"},
%%%     {document_root, "/tmp/my_api"},
%%%     {bind_address, {127,0,0,1}},
%%%     {modules, [httpd_router]}
%%% ]).
%%% '''
%%%
%%% == Handler Functions ==
%%%
%%% Handlers receive a context map and return a response tuple:
%%%
%%% ```
%%% hello(_Ctx) ->
%%%     {json, 200, #{message => <<"Hello!">>}}.
%%%
%%% user(#{params := #{id := Id}}) ->
%%%     {json, 200, #{id => list_to_binary(Id)}}.
%%% '''
%%%
%%% Supported response types:
%%% <ul>
%%%   <li>`{json, Code, Body}' - JSON response</li>
%%%   <li>`{json, Code, Headers, Body}' - JSON with extra headers</li>
%%%   <li>`{text, Code, ContentType, Body}' - Text/HTML response</li>
%%%   <li>`{status, Code}' - Status code only, no body</li>
%%%   <li>`{headers, Code, Headers}' - Status with custom headers</li>
%%%   <li>`{stream, Code, Headers, StreamFun}' - Chunked streaming</li>
%%%   <li>`{raw, Code, Headers, Body}' - Raw response</li>
%%% </ul>
%%%
%%% == Middleware ==
%%%
%%% Middlewares are functions `fun(Ctx) -> {ok, Ctx} | {error, Response}'
%%% executed in order before the handler. On error, the chain is
%%% short-circuited and the error response is sent directly.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(httpd_router).

%% Public API
-export([
    start/0,
    start/1,
    start/2,
    add_route/3,
    add_route/4,
    table_add_route/5,
    set_option/2,
    set_option/3,
    print_routes/0,
    print_routes/1,
    mk_table_name/2
]).

%% httpd callback
-export([do/1]).

%% Internal (exported for testing)
-export([
    match_path/2,
    find_route/3,
    execute_middlewares/2
]).

-include_lib("inets/include/httpd.hrl").
-include("httpd_router.hrl").

-define(TABLE_NAME, httpd_routes).

%%--------------------------------------------------------------------
%% Public API
%%--------------------------------------------------------------------

%% @doc Start the router with the default table name.
%%
%% Creates the default route table (`httpd_routes') and ensures the
%% `httpd_router' application is running.
%% @end
-spec start() -> {ok, atom()} | {error, term()}.
start() ->
    start(?TABLE_NAME).

%% @doc Start the router with a named table.
%%
%% Useful when running multiple httpd instances on different ports,
%% each with its own route table. See also {@link mk_table_name/2}.
%% @end
-spec start(atom()) -> {ok, atom()} | {error, term()}.
start(TableName) ->
    start(TableName, #{}).

%% @doc Start the router with a named table and options.
%%
%% Options:
%% <ul>
%%   <li>`no_match' - What to do when no route matches:
%%     <ul>
%%       <li>`404' (default) - Return a 404 Not Found response.</li>
%%       <li>`passthrough' - Pass the request to the next module in
%%           the httpd pipeline (e.g. `mod_get' for static files).</li>
%%     </ul>
%%   </li>
%% </ul>
%% @end
-spec start(atom(), map()) -> {ok, atom()} | {error, term()}.
start(TableName, Options) ->
    ensure_started(),
    httpd_router_server:create_table(TableName, Options).

%% @doc Add a route to the default table.
%%
%% Equivalent to `add_route(Method, PathPattern, Handler, [])'.
%% @end
-spec add_route(string(), string(), function()) -> ok.
add_route(Method, PathPattern, Handler) ->
    add_route(Method, PathPattern, Handler, []).

%% @doc Add a route with middlewares to the default table.
%%
%% `Method' is an HTTP method string (`"GET"', `"POST"', etc.) or
%% a CRUD specification string (e.g. `"CRUD"', `"CR"', `"RD"').
%%
%% `PathPattern' is a URL path with optional named parameters
%% prefixed with `:' (e.g. `"/users/:id"').
%%
%% `Handler' is a `fun(Ctx) -> Response' where `Ctx' is a map and
%% `Response' is a response tuple.
%%
%% `Middlewares' is a list of `fun(Ctx) -> {ok, Ctx} | {error, Response}'
%% functions executed in order before the handler.
%% @end
-spec add_route(string(), string(), function(), [function()]) -> ok.
add_route(Method, PathPattern, Handler, Middlewares) ->
    table_add_route(?TABLE_NAME, Method, PathPattern, Handler, Middlewares).

%% @doc Add a route to a specific named table.
%%
%% Same as {@link add_route/4} but targets a specific route table.
%% Use when running multiple httpd instances with separate routing.
%% @end
-spec table_add_route(atom(), string(), string(), function(), [function()]) ->
    ok.
table_add_route(TableName, Method, PathPattern, Handler, Middlewares) ->
    httpd_router_server:add_route(
        TableName, Method, PathPattern, Handler, Middlewares
    ).

%% @doc Set an option on the default table.
%% @see set_option/3
-spec set_option(atom(), term()) -> ok | {error, term()}.
set_option(Key, Value) ->
    set_option(?TABLE_NAME, Key, Value).

%% @doc Set an option on a specific table.
%%
%% Currently supported options:
%% <ul>
%%   <li>`no_match' - `404 | passthrough'</li>
%% </ul>
%% @end
-spec set_option(atom(), atom(), term()) -> ok | {error, term()}.
set_option(TableName, Key, Value) ->
    httpd_router_server:set_option(TableName, Key, Value).

%% @doc Create a table name from IP address and port number.
%%
%% Useful when setting up separate route tables for different
%% httpd listener instances.
%%
%% Example: `mk_table_name({127,0,0,1}, 8080)' returns
%% `httpd_routes_127.0.0.1_8080'.
%% @end
-spec mk_table_name(inet:ip_address(), inet:port_number()) -> atom().
mk_table_name(IP, Port) ->
    list_to_atom(
        "httpd_routes_" ++ inet:ntoa(IP) ++ "_" ++ integer_to_list(Port)
    ).

%%--------------------------------------------------------------------
%% Route printing
%%--------------------------------------------------------------------

%% @doc Print all routes from all tables to stdout.
%%
%% Useful for debugging and verifying the registered routes.
%% @end
-spec print_routes() -> ok.
print_routes() ->
    {ok, Tables} = httpd_router_server:get_tables(),
    lists:foreach(
        fun({TableName, _Opts}) -> print_routes(TableName) end, Tables
    ).

%% @doc Print all routes from a specific table to stdout.
%% @end
-spec print_routes(atom()) -> ok.
print_routes(TableName) ->
    Routes = ets:tab2list(TableName),
    io:format("~n>>> TABLE(~w)~n", [TableName]),
    io:format(
        "~-8.s ~-40.s ~-5.s ~-9.s ~s~n",
        ["METHOD", "PATH PATTERN", "CRUD", "ACTION", "HANDLER"]
    ),
    io:format(
        "~-8.s ~-40.s ~-5.s ~-9.s ~s~n",
        ["------", "------------", "----", "------", "-------"]
    ),
    Sorted = lists:keysort(#route.path_pattern, Routes),
    lists:foreach(fun print_route/1, Sorted),
    ok.

print_route(#route{
    method = Method,
    path_pattern = PP,
    handler = Handler,
    action = Action,
    crud = Crud
}) ->
    CrudStr =
        case Crud of
            undefined -> "-";
            _ -> Crud
        end,
    ActionStr =
        case Action of
            undefined -> "-";
            _ -> atom_to_list(Action)
        end,
    HandlerStr =
        case Handler of
            undefined -> "-";
            _ -> io_lib:format("~w", [Handler])
        end,
    io:format(
        "~-8.s ~-40.s ~-5.s ~-9.s ~s~n",
        [Method, PP, CrudStr, ActionStr, HandlerStr]
    ).

%%--------------------------------------------------------------------
%% httpd callback: do/1
%%--------------------------------------------------------------------

%% @doc The httpd callback module entry point.
%%
%% This function is called by `httpd' for each incoming request.
%% It parses the request, matches it against registered routes,
%% executes any middlewares, calls the handler, and returns the
%% response in the format expected by `httpd'.
%%
%% Do not call this function directly. Instead, include
%% `httpd_router' in the `{modules, [...]}' list of your httpd
%% configuration.
%% @end
do(
    #mod{
        method = MethodStr,
        request_uri = RequestURI,
        entity_body = Body,
        parsed_header = Headers,
        data = Data
    } = ModData
) ->
    %% Check if already handled by another module
    case proplists:get_value(response, Data) of
        undefined ->
            Method = MethodStr,
            {Path, QueryStr} = split_uri(RequestURI),
            TableName = get_table_name(ModData),
            case find_route(Method, Path, TableName) of
                {ok, #route{action = options, crud = Crud}} ->
                    Response = build_options_response(Crud),
                    send_response(ModData, Response);
                {ok, #route{
                    handler = Handler,
                    middlewares = Middlewares,
                    params = Params,
                    action = Action
                }} ->
                    Ctx = build_ctx(
                        ModData,
                        Method,
                        Path,
                        QueryStr,
                        Body,
                        Headers,
                        Params,
                        Action
                    ),
                    case execute_middlewares(Middlewares, Ctx) of
                        {ok, FinalCtx} ->
                            try
                                Response = Handler(FinalCtx),
                                send_response(ModData, Response)
                            catch
                                Class:Error:Stack ->
                                    ErrMsg = io_lib:format(
                                        "~p:~p~n~p",
                                        [Class, Error, Stack]
                                    ),
                                    send_response(
                                        ModData,
                                        {text, 500, "text/plain",
                                            iolist_to_binary(ErrMsg)}
                                    )
                            end;
                        {error, ErrorResponse} ->
                            send_response(ModData, ErrorResponse)
                    end;
                not_found ->
                    handle_not_found(ModData, TableName)
            end;
        _ ->
            {proceed, Data}
    end.

%%--------------------------------------------------------------------
%% Path matching
%%--------------------------------------------------------------------

%% @doc Match a path pattern against an actual path, extracting params.
%%
%% Path parameters are segments prefixed with `:' in the pattern.
%% Returns `{true, Params}' on match where `Params' is a map of
%% `atom() => string()' pairs, or `false' if the path does not match.
%%
%% Example:
%% ```
%% {true, #{id => "42"}} = httpd_router:match_path("/users/:id", "/users/42").
%% false = httpd_router:match_path("/users/:id", "/posts/42").
%% '''
%% @end
-spec match_path(string(), string()) -> {true, map()} | false.
match_path(Pattern, Path) ->
    PatternSegments = string:split(Pattern, "/", all),
    PathSegments = string:split(Path, "/", all),
    case length(PatternSegments) =:= length(PathSegments) of
        true -> match_segments(PatternSegments, PathSegments, #{});
        false -> false
    end.

match_segments([], [], Params) ->
    {true, Params};
match_segments([[$: | ParamName] | RestPattern], [Value | RestPath], Params) ->
    match_segments(RestPattern, RestPath, Params#{
        list_to_atom(ParamName) => Value
    });
match_segments([Same | RestPattern], [Same | RestPath], Params) ->
    match_segments(RestPattern, RestPath, Params);
match_segments(_, _, _) ->
    false.

%% @doc Find a matching route for the given method and path.
%%
%% Searches the named ETS table for a route whose method matches
%% and whose path pattern matches the given path. Returns the
%% matched route with extracted parameters, or `not_found'.
%% @end
-spec find_route(string(), string(), atom()) -> {ok, #route{}} | not_found.
find_route(Method, Path, TableName) ->
    Routes = ets:tab2list(TableName),
    MethodRoutes = [R || #route{method = M} = R <- Routes, M =:= Method],
    find_matching(MethodRoutes, Path).

find_matching([], _Path) ->
    not_found;
find_matching([#route{path_pattern = PP} = Route | Rest], Path) ->
    case match_path(PP, Path) of
        {true, Params} ->
            {ok, Route#route{params = Params}};
        false ->
            find_matching(Rest, Path)
    end.

%%--------------------------------------------------------------------
%% Middleware execution
%%--------------------------------------------------------------------

%% @doc Execute a list of middleware functions in sequence.
%%
%% Each middleware receives the current context map and must return
%% either `{ok, NewCtx}' to continue the chain, or
%% `{error, Response}' to short-circuit and return an error response.
%%
%% If a middleware throws an exception, a 500 error response is
%% generated automatically.
%% @end
execute_middlewares([], Ctx) ->
    {ok, Ctx};
execute_middlewares([Middleware | Rest], Ctx) ->
    try Middleware(Ctx) of
        {ok, NewCtx} ->
            execute_middlewares(Rest, NewCtx);
        {error, _Response} = Error ->
            Error
    catch
        Class:Error:Stack ->
            ErrMsg = io_lib:format(
                "Middleware error: ~p:~p~n~p",
                [Class, Error, Stack]
            ),
            {error, {text, 500, "text/plain", iolist_to_binary(ErrMsg)}}
    end.

%%--------------------------------------------------------------------
%% Request context builder
%%--------------------------------------------------------------------

build_ctx(ModData, Method, Path, QueryStr, Body, Headers, Params, Action) ->
    Query = parse_query(QueryStr),
    HeaderMap = maps:from_list([{string:lowercase(K), V} || {K, V} <- Headers]),
    BodyBin =
        if
            is_list(Body) -> list_to_binary(Body);
            is_binary(Body) -> Body;
            true -> <<>>
        end,
    Ctx = #{
        mod => ModData,
        method => list_to_binary(Method),
        path => Path,
        params => Params,
        query => Query,
        body => BodyBin,
        headers => HeaderMap,
        opaque => #{}
    },
    case Action of
        undefined -> Ctx;
        _ -> Ctx#{action => Action}
    end.

parse_query("") ->
    #{};
parse_query(QueryStr) ->
    Pairs = string:split(QueryStr, "&", all),
    maps:from_list(
        lists:filtermap(
            fun(Pair) ->
                case string:split(Pair, "=") of
                    [Key, Val] ->
                        {true, {list_to_binary(Key), list_to_binary(Val)}};
                    _ ->
                        false
                end
            end,
            Pairs
        )
    ).

%%--------------------------------------------------------------------
%% Response translation
%%--------------------------------------------------------------------

send_response(ModData, {json, Code, Body}) ->
    send_response(ModData, {json, Code, [], Body});
send_response(ModData, {json, Code, ExtraHeaders, Body}) ->
    JsonBody = json:encode(Body),
    Headers = [{"content-type", "application/json"} | ExtraHeaders],
    send_final(ModData, Code, Headers, JsonBody);
send_response(ModData, {text, Code, ContentType, Body}) ->
    Headers = [{"content-type", ContentType}],
    send_final(ModData, Code, Headers, Body);
send_response(ModData, {status, Code}) ->
    send_final(ModData, Code, [], <<>>);
send_response(ModData, {headers, Code, Headers}) ->
    send_final(ModData, Code, Headers, <<>>);
send_response(ModData, {raw, Code, Headers, Body}) ->
    send_final(ModData, Code, Headers, Body);
send_response(#mod{data = Data} = ModData, {stream, Code, Headers, StreamFun}) ->
    %% For streaming, we send headers and chunks directly on the socket
    Socket = ModData#mod.socket,
    SocketType = ModData#mod.socket_type,
    send_stream_headers(SocketType, Socket, Code, Headers),
    SendChunk = fun(Chunk) ->
        httpd_socket:deliver(SocketType, Socket, Chunk)
    end,
    StreamFun(SendChunk),
    BodySize = 0,
    {proceed, [{response, {already_sent, Code, BodySize}} | Data]};
send_response(ModData, _Other) ->
    send_final(
        ModData, 500, [{"content-type", "text/plain"}], "Internal Server Error"
    ).

send_final(#mod{data = Data}, Code, Headers, Body) ->
    %% httpd expects: {response, {response, HeaderProplist, Body}}
    %% where HeaderProplist contains {code, N} and optionally header tuples.
    %% We must include content-length or the client will hang waiting for more data.
    BodyBin = iolist_to_binary(Body),
    ContentLength = integer_to_list(byte_size(BodyBin)),
    HttpdHeaders = [{code, Code}, {"content-length", ContentLength} | Headers],
    {proceed, [{response, {response, HttpdHeaders, BodyBin}} | Data]}.

send_stream_headers(SocketType, Socket, Code, Headers) ->
    StatusLine = io_lib:format("HTTP/1.1 ~B ~s\r\n", [Code, reason_phrase(Code)]),
    HeaderLines = [[K, ": ", V, "\r\n"] || {K, V} <- Headers],
    httpd_socket:deliver(
        SocketType,
        Socket,
        [StatusLine, HeaderLines, "\r\n"]
    ).

%%--------------------------------------------------------------------
%% OPTIONS / CORS handling
%%--------------------------------------------------------------------

build_options_response(Crud) when is_list(Crud) ->
    Methods = build_allow_methods(Crud),
    {headers, 204, [
        {"allow", Methods},
        {"access-control-allow-origin", "*"},
        {"access-control-allow-methods", Methods}
    ]}.

build_allow_methods(Crud) ->
    MethodList =
        lists:flatmap(
            fun
                ($C) -> ["POST"];
                ($R) -> ["GET"];
                ($U) -> ["PUT", "PATCH"];
                ($D) -> ["DELETE"]
            end,
            Crud
        ) ++ ["OPTIONS"],
    string:join(MethodList, ", ").

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

split_uri(URI) ->
    case string:split(URI, "?") of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, ""}
    end.

get_table_name(#mod{config_db = ConfigDb}) ->
    case httpd_util:lookup(ConfigDb, httpd_router_table, undefined) of
        undefined -> ?TABLE_NAME;
        TableName -> TableName
    end.

handle_not_found(#mod{data = Data} = ModData, TableName) ->
    case httpd_router_server:get_options(TableName) of
        {ok, #{no_match := passthrough}} ->
            {proceed, Data};
        _ ->
            send_response(ModData, {text, 404, "text/plain", "Not Found"})
    end.

ensure_started() ->
    case whereis(httpd_router_server) of
        undefined ->
            application:ensure_all_started(httpd_router);
        _ ->
            ok
    end.

reason_phrase(200) -> "OK";
reason_phrase(201) -> "Created";
reason_phrase(204) -> "No Content";
reason_phrase(301) -> "Moved Permanently";
reason_phrase(302) -> "Found";
reason_phrase(304) -> "Not Modified";
reason_phrase(400) -> "Bad Request";
reason_phrase(401) -> "Unauthorized";
reason_phrase(403) -> "Forbidden";
reason_phrase(404) -> "Not Found";
reason_phrase(405) -> "Method Not Allowed";
reason_phrase(500) -> "Internal Server Error";
reason_phrase(Code) -> integer_to_list(Code).
