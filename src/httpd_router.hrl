-record(route, {
    method :: string(),
    path_pattern :: string(),
    path_segments :: [string()],
    segment_count :: non_neg_integer(),
    handler :: function(),
    middlewares :: [function()],
    crud :: string() | undefined,
    action :: atom() | undefined,
    params :: map() | undefined
}).
