#!/usr/bin/env nu
# Compatibility entry point. Fixtures are generated and inspected by Python.
const project_dir = path self ..
def main [fixture?: string, --url: string = "http://127.0.0.1:3200"] {
    ^python3 ($project_dir | path join scripts elm-browser-acceptance.py) --url $url --checks "fitting,mixed_and_saved,preview_recovery"
    if $env.LAST_EXIT_CODE != 0 { error make {msg: "Elm browser acceptance failed"} }
}
