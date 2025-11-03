export VSCODE_CLI_APP_NAME="cortexide"
export VSCODE_CLI_BINARY_NAME="cortexide-server"
export VSCODE_CLI_DOWNLOAD_URL="https://github.com/cortexide/cortexide/releases"
export VSCODE_CLI_QUALITY="stable"
export VSCODE_CLI_UPDATE_URL="https://raw.githubusercontent.com/cortexide/versions/refs/heads/main"

cargo build --release --target aarch64-apple-darwin --bin=code

cp target/aarch64-apple-darwin/release/code "../../VSCode-darwin-arm64/CortexIDE.app/Contents/Resources/app/bin/cortexide-tunnel"

"../../VSCode-darwin-arm64/CortexIDE.app/Contents/Resources/app/bin/cortexide-tunnel" serve-web


# export CARGO_NET_GIT_FETCH_WITH_CLI="true"
# export VSCODE_CLI_APP_NAME="cortexide-insiders"
# export VSCODE_CLI_BINARY_NAME="cortexide-server-insiders"
# export VSCODE_CLI_DOWNLOAD_URL="https://github.com/cortexide/cortexide-insiders/releases"
# export VSCODE_CLI_QUALITY="insider"
# export VSCODE_CLI_UPDATE_URL="https://raw.githubusercontent.com/cortexide/versions/refs/heads/main"

# cargo build --release --target aarch64-apple-darwin --bin=code

# cp target/aarch64-apple-darwin/release/code "../../VSCode-darwin-arm64/VSCodium - Insiders.app/Contents/Resources/app/bin/codium-tunnel-insiders"

# "../../VSCode-darwin-arm64/VSCodium - Insiders.app/Contents/Resources/app/bin/codium-insiders" serve-web
