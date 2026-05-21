-record(route, {
    key :: {Method :: string(), PathPattern :: string()},
    method :: string(),
    path_pattern :: string(),
    handler :: function(),
    middlewares :: [function()],
    crud :: string() | undefined,
    action :: atom() | undefined,
    params :: map() | undefined
}).
