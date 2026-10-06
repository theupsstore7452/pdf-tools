#!/usr/bin/env nu
const project_dir = path self ..
def main [] {
    cd $project_dir
    ^scripts/acceptance.sh
    if $env.LAST_EXIT_CODE != 0 { error make {msg: "Runtime acceptance failed"} }
}
