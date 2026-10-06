use std::{env, fs, path::PathBuf};
fn main() {
    println!("cargo:rerun-if-changed=src/imposition/model.rs");
    println!("cargo:rerun-if-changed=src/web/gang_up.rs");
    if env::var_os("CARGO_FEATURE_ELM_CODEGEN").is_none() {
        return;
    }
    // elm-rs 0.2.3 cannot parse Serde's default = "function". Compile a
    // generation-only copy of the same declarations, removing defaults that
    // do not affect the full current wire schema. Production Serde is untouched.
    let mut source = fs::read_to_string("src/imposition/model.rs").expect("wire model");
    let handlers = fs::read_to_string("src/web/gang_up.rs").expect("wire handlers");
    for name in ["PreparedSourceResponse", "PreviewBatchRequest"] {
        let start = handlers
            .find(&format!("struct {name}"))
            .expect("wire struct");
        let start = handlers[..start].rfind("#[derive(").expect("wire derive");
        let end = start + handlers[start..].find("\n}").expect("wire end") + 2;
        source.push('\n');
        source.push_str(
            &handlers[start..end]
                .replace("#[derive(Serialize)]", "#[derive(Serialize, Deserialize)]")
                .replace(
                    "#[derive(Deserialize)]",
                    "#[derive(Serialize, Deserialize)]",
                )
                .replace(
                    "struct PreparedSourceResponse",
                    "pub(super) struct PreparedSourceResponse",
                ),
        );
    }
    let source = source
        .replace(
            "#[derive(",
            "#[derive(elm_rs::Elm, elm_rs::ElmEncode, elm_rs::ElmDecode, ",
        )
        .replace(
            "#[serde(default = \"default_created_bleed_amount\")]",
            "#[serde(default)]",
        );
    fs::write(
        PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR")).join("elm_model.rs"),
        source,
    )
    .expect("write generation model");
}
