#!/usr/bin/env nu
# Compatible launcher; Elm builds and Axum owns the HTTP origin.
def main [] {
    ^bash ((path self | path dirname) | path join dev.sh)
    if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE }
}
