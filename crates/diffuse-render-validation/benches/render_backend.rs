fn main() -> std::process::ExitCode {
    diffuse_render_validation::native_pass_benchmark::run_command(
        std::env::args().skip(1).collect(),
        Some("mesh"),
        "renderer benchmark failed",
    )
}
