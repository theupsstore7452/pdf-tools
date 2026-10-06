fn main() -> pdf_tools_server::AppResult<()> {
    if std::env::args().any(|arg| arg == "--fixtures") {
        print!("{}", pdf_tools_server::elm::contract_fixtures()?);
    } else {
        print!("{}", pdf_tools_server::elm::generate());
    }
    Ok(())
}
