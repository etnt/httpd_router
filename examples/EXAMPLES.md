# Examples

## Running the Examples

Start a rebar3 shell and add the examples directory to the code path:

```erlang
$ rebar3 shell

1> code:add_path("./examples").
true
```

### CRUD API

```erlang
2> crud_api:start(9292).
CRUD API started on http://127.0.0.1:9292/
Try:
  curl http://127.0.0.1:9292/api/users
  curl http://127.0.0.1:9292/api/users/42
  curl -is -X POST -H 'Content-Type: application/json' -d '{"name":"Lisa"}' http://127.0.0.1:9292/api/users
  curl -X DELETE http://127.0.0.1:9292/api/users/42
  curl -X OPTIONS http://127.0.0.1:9292/api/users
ok
```

```bash
$ curl http://127.0.0.1:9292/api/users
{"users":[{"id":"1","name":"Alice"},{"id":"2","name":"Bob"}]}

$ curl http://127.0.0.1:9292/api/users/42
{"id":"42","name":"User 42"}

$ curl -is -X POST -H 'Content-Type: application/json' -d '{"name":"Lisa"}' http://127.0.0.1:9292/api/users
HTTP/1.1 201 Created
Date: Thu, 21 May 2026 08:41:26 GMT
Server: inets/9.6.2
Content-Length: 44
Content-Type: application/json
Location: /api/users/41

{"id":"41","name":"Lisa","status":"created"}

$ curl -X DELETE http://127.0.0.1:9292/api/users/42
{"id":"42","status":"deleted"}
```

#### CORS Preflight

```bash
$ curl -is -X OPTIONS \
  -H 'Origin: http://example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: Content-Type' \
  http://127.0.0.1:9292/api/users
HTTP/1.1 204 No Content
Date: Thu, 21 May 2026 08:42:00 GMT
Server: inets/9.6.2
Allow: POST, GET, PUT, PATCH, DELETE, OPTIONS
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: POST, GET, PUT, PATCH, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Max-Age: 86400
```

> **Note:** OPTIONS support requires the OTP patch for
> `httpd_request:validate/3` (see the Known Limitations section in
> the main README).

### Simple API

```erlang
3> simple_api:start(9393).
Simple API started on http://127.0.0.1:9393/
Try:
  curl http://127.0.0.1:9393/
  curl http://127.0.0.1:9393/hello
  curl http://127.0.0.1:9393/hello?name=Erlang
  curl http://127.0.0.1:9393/user/42
ok
```

```bash
$ curl http://127.0.0.1:9393/
{"message":"Welcome to the Simple API!"}

$ curl http://127.0.0.1:9393/hello
{"greeting":"Hello, world!"}

$ curl 'http://127.0.0.1:9393/hello?name=Erlang'
{"greeting":"Hello, Erlang!"}

$ curl http://127.0.0.1:9393/user/42
{"id":"42","name":"User 42"}
```

### Route Isolation

Each server instance has its own route table — routes registered on one
port are not visible on the other:

```bash
$ curl http://127.0.0.1:9292/hello
Not Found

$ curl http://127.0.0.1:9393/api/users
Not Found
```
