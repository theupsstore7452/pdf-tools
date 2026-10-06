#!/usr/bin/env nu
# Kept as a compatible entry point for existing automation.
def main [project: string = "pdf-app"] {
    if $project != "pdf-app" { error make {msg: $"Unknown project: ($project)"} }
    ^bash ((path self | path dirname) | path join check.sh)
    if $env.LAST_EXIT_CODE != 0 { exit $env.LAST_EXIT_CODE }
}
