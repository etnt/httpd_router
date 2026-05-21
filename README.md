# httpd_router

[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://etnt.github.io/httpd_router/)
[![Tests](https://github.com/etnt/httpd_router/actions/workflows/tests.yml/badge.svg)](https://github.com/etnt/httpd_router/actions/workflows/tests.yml)

A declarative routing module for OTP's built-in `httpd` web server.

`httpd_router` implements the `do/1` callback expected by the `httpd` module
pipeline, providing clean, declarative routing without external dependencies.

## Features

* Declarative route registration with path patterns (e.g. `/users/:id`)
* Middleware chains for cross-cutting concerns (auth, logging, CORS)
* CRUD route shortcuts (`"CRUD"`, `"CR"`, `"RD"`, etc.)
* Automatic OPTIONS/CORS preflight handling
* Clean request context map passed to handlers
* Multiple named route tables for different server instances
* Streaming response support
* Configurable fallthrough behaviour (404 or passthrough to next module)
* Zero external dependencies — pure OTP

See the [examples](examples/EXAMPLES.md) for runnable demo sessions.

## Build

```bash
make          # Compile
make test     # Run EUnit tests
make doc      # Generate documentation (doc/)
make shell    # Start interactive shell
```

## Quick Start

```erlang
{ok, _} = application:ensure_all_started(inets),
{ok, _} = application:ensure_all_started(httpd_router),
{ok, _} = httpd_router:start(),

%% Register routes
httpd_router:add_route("GET", "/hello", fun my_handler:hello/1),
httpd_router:add_route("GET", "/user/:id", fun my_handler:user/1),
httpd_router:add_route("CRUD", "/api/items", fun my_handler:items/1, [fun auth:check/1]),

%% Start httpd with httpd_router in the module pipeline
DocRoot = "/tmp/my_api",
filelib:ensure_dir(DocRoot ++ "/x"),
{ok, _} = inets:start(httpd, [
    {port, 8080},
    {server_name, "my_api"},
    {server_root, "/tmp"},
    {document_root, DocRoot},
    {bind_address, {127,0,0,1}},
    {modules, [httpd_router]}
]).
```

## Handler Functions

Handlers receive a context map and return a response tuple:

```erlang
hello(_Ctx) ->
    {json, 200, #{message => <<"Hello!">>}}.

user(#{params := #{id := Id}}) ->
    {json, 200, #{id => list_to_binary(Id)}}.
```

### Context Map

```erlang
#{
    mod     => ModData,           %% Original #mod{} record
    method  => <<"GET">>,         %% HTTP method as binary
    path    => "/users/42",       %% Request path
    params  => #{id => "42"},     %% Extracted path parameters
    query   => #{<<"k">> => <<"v">>}, %% Parsed query string
    body    => Body,              %% Raw request body (unparsed)
    headers => #{...},            %% Request headers as map
    action  => show,             %% CRUD action (if applicable)
    opaque  => #{}               %% User data (set by middleware)
}
```

### Response Types

| Tuple | Description |
|-------|-------------|
| `{json, Code, Body}` | JSON response |
| `{json, Code, Headers, Body}` | JSON with extra headers |
| `{text, Code, ContentType, Body}` | Text/HTML response |
| `{status, Code}` | Status code only |
| `{headers, Code, Headers}` | Status with custom headers |
| `{stream, Code, Headers, StreamFun}` | Chunked streaming |
| `{raw, Code, Headers, Body}` | Raw response |

## Middleware

Middlewares are functions executed in order before the handler:

```erlang
auth_middleware(#{headers := Headers} = Ctx) ->
    case maps:get("authorization", Headers, undefined) of
        undefined ->
            {error, {json, 401, #{error => <<"Unauthorized">>}}};
        _Token ->
            {ok, Ctx#{opaque => #{authenticated => true}}}
    end.

httpd_router:add_route("GET", "/secret", fun handler:secret/1, [fun auth_middleware/1]).
```

## CRUD Routes

A CRUD string expands into multiple routes automatically:

| CRUD | Path | Method | Action |
|------|------|--------|--------|
| R | `/users` | GET | index |
| R | `/users/:id` | GET | show |
| C | `/users` | POST | create |
| U | `/users/:id` | PUT | replace |
| U | `/users/:id` | PATCH | modify |
| D | `/users/:id` | DELETE | delete |

```erlang
httpd_router:add_route("CRUD", "/api/users", fun my_handler:users/1).
```

## TLS Support

TLS is handled at the `httpd` configuration level — the router is
transport-agnostic:

```erlang
{ok, _} = inets:start(httpd, [
    {port, 8443},
    {server_name, "my_api"},
    {server_root, "/tmp"},
    {document_root, "/tmp/my_api"},
    {bind_address, {127,0,0,1}},
    {modules, [httpd_router]},
    {socket_type, {ssl, [
        {certfile, "/path/to/cert.pem"},
        {keyfile, "/path/to/key.pem"}
    ]}}
]).
```

## Known Limitations

### OPTIONS / CORS Preflight

OTP's `httpd` does not include `OPTIONS` in its hardcoded list of allowed
HTTP methods (`httpd_request:validate/3`). Requests using `OPTIONS` are
rejected with `501 Not Implemented` before the module pipeline (and thus
`httpd_router`) is invoked.

This means automatic CORS preflight handling is not possible with the
stock `httpd`. Workarounds:

* Place a reverse proxy (e.g. nginx, Caddy) in front that handles
  OPTIONS/CORS before forwarding to httpd.
* Use a different HTTP server (e.g. Cowboy) if CORS preflight support
  is critical.
