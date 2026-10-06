#!/usr/bin/env nu
const project_dir = path self ..
def main [--image: string = "pdf-tools-elm:validation", --skip-build, --engine: string = "docker"] {
    let options = if $skip_build { ["--skip-build"] } else { [] }
    ^python3 ($project_dir | path join scripts container-acceptance.py) --engine $engine --image $image ...$options
    if $env.LAST_EXIT_CODE != 0 { error make {msg: "Container acceptance failed"} }
}
