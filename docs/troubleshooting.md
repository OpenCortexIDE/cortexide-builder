# Troubleshooting

## Table of Contents

- [Linux](#linux)
  - [Fonts showing up as rectangles](#linux-fonts-rectangle)
  - [Text and/or the entire interface not appearing](#linux-rendering-glitches)
  - [Global menu workaround for KDE](#linux-kde-global-menu)
  - [Flatpak most common issues](#linux-flatpak-most-common-issues)
  - [Remote SSH doesn't work](#linux-remote-ssh)
- [macOS](#macos)
  - [App can't be opened because Apple cannot check it for malicious software](#macos-unidentified-developer)
  - ["VSCodium.app" is damaged and can't be opened. You should move it to the Bin](#macos-quarantine)
  - [App installs but doesn't open on Intel Mac](#macos-intel-not-opening)
  - [Blank screen after installation](#macos-blank-screen)


## <a id="linux"></a>Linux

#### <a id="linux-fonts-rectangle"></a>*Fonts showing up as rectangles*

The following command should help:

```
rm -rf ~/.cache/fontconfig
rm -rf ~/snap/codium/common/.cache
fc-cache -r
```

#### <a id="linux-rendering-glitches"></a>*Text and/or the entire interface not appearing*

You have likely encountered [a bug in Chromium and Electron](microsoft/vscode#190437) when compiling Mesa shaders, which has affected all Visual Studio Code and VSCodium versions for Linux distributions since 1.82.  The current workaround (see microsoft/vscode#190437) is to delete the GPU cache as follows:

```bash
rm -rf ~/.config/VSCodium/GPUCache
```

#### <a id="linux-kde-global-menu"></a>*Global menu workaround for KDE*

Install these packages on Fedora:

* libdbusmenu-devel
* dbus-glib-devel
* libdbusmenu

On Ubuntu this package is called `libdbusmenu-glib4`.

Credits: [Gerson](https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/issues/91)

#### <a id="linux-flatpak-most-common-issues"></a>*Flatpak most common issues*

- blurry screen with HiDPI on wayland run:
  ```bash
  flatpak override --user --nosocket=wayland com.vscodium.codium
  ```
- To execute commands on the host system, run inside the sandbox
  ```bash
  flatpak-spawn --host <COMMAND>
  # or
  host-spawn <COMMAND>
  ```
- Where is my X extension? AKA modify product.json
  TL;DR: use https://open-vsx.org/extension/zokugun/vsix-manager

- SDKs
  see [this](https://github.com/flathub/com.vscodium.codium?tab=readme-ov-file#sdks)

- If you have any other problems with the flatpak package try to look on the [FAQ](https://github.com/flathub/com.vscodium.codium?tab=readme-ov-file#faq) maybe the solution is already there or open an [issue](https://github.com/flathub/com.vscodium.codium/issues).

##### <a id="linux-remote-ssh"></a>*Remote SSH doesn't work*

Use the VSCodium's compatible extension [Open Remote - SSH](https://open-vsx.org/extension/jeanp413/open-remote-ssh).

On the server, in the `sshd` config, `AllowTcpForwarding` need to be set to `yes`.

It might requires additional dependeincies due to the OS/distro (alpine).

## <a id="macos"></a>macOS

Since the App is signed with a self-signed certificate, on the first launch, you might see the following messages:

#### <a id="macos-unidentified-developer"></a>*App can't be opened because Apple cannot check it for malicious software*

You can right-click the App and choose `Open`.

#### <a id="macos-quarantine"></a>*"VSCodium.app" is damaged and can't be opened. You should move it to the Bin.*

The following command will remove the quarantine attribute.

```
xattr -r -d com.apple.quarantine /Applications/VSCodium.app
```

#### <a id="macos-intel-not-opening"></a>*App installs but doesn't open on Intel Mac*

If the app installs successfully but doesn't open on Intel Mac (x64), try the following troubleshooting steps:

1. **Remove quarantine attribute** (if downloaded from the internet):
   ```bash
   xattr -r -d com.apple.quarantine /Applications/CortexIDE.app
   ```

2. **Verify code signing**:
   ```bash
   codesign -dv --verbose=4 /Applications/CortexIDE.app
   ```
   Look for errors or warnings about invalid signatures.

3. **Check notarization status**:
   ```bash
   spctl --assess --verbose /Applications/CortexIDE.app
   ```
   If notarization failed, you may need to check the build logs.

4. **Verify architecture**:
   ```bash
   file /Applications/CortexIDE.app/Contents/MacOS/CortexIDE
   ```
   Should show `x86_64` for Intel Macs. If it shows `arm64`, you have the wrong build.

5. **Check Console logs**:
   - Open Console.app
   - Filter for "CortexIDE" or the app's process name
   - Look for crash reports or error messages

6. **Try launching from Terminal**:
   ```bash
   /Applications/CortexIDE.app/Contents/MacOS/CortexIDE
   ```
   This will show any error messages that might be hidden when launching from Finder.

7. **Check entitlements**:
   ```bash
   codesign -d --entitlements :- /Applications/CortexIDE.app
   ```
   Verify that required entitlements are present.

8. **If the app crashes immediately**, check for crash reports:
   ```bash
   ls -la ~/Library/Logs/DiagnosticReports/ | grep CortexIDE
   ```

9. **For Gatekeeper issues**, you may need to allow the app in System Settings:
   - System Settings → Privacy & Security → Scroll to "Security"
   - If the app is blocked, click "Allow Anyway"

10. **If using Rosetta 2** (running Intel app on Apple Silicon), ensure Rosetta 2 is installed:
    ```bash
    softwareupdate --install-rosetta
    ```

#### <a id="macos-blank-screen"></a>*Blank screen after installation*

If the app launches but shows a blank/white screen, try the following solutions in order:

1. **Clear GPU cache** (most common fix):
   ```bash
   rm -rf ~/Library/Application\ Support/CortexIDE/GPUCache
   rm -rf ~/Library/Application\ Support/CortexIDE/Code\ Cache
   ```
   Then restart the app.

2. **Verify critical files exist in the app bundle**:
   ```bash
   ls -la /Applications/CortexIDE.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html
   ls -la /Applications/CortexIDE.app/Contents/Resources/app/out/main.js
   ```
   If these files are missing, the build may have failed. Rebuild the application.

3. **Check Console logs for errors**:
   - Open Console.app (Applications → Utilities → Console)
   - Filter for "CortexIDE" or "Electron"
   - Look for rendering errors, GPU errors, or file not found errors

4. **Try launching with hardware acceleration disabled** (temporary workaround):
   ```bash
   /Applications/CortexIDE.app/Contents/MacOS/CortexIDE --disable-gpu
   ```
   If this works, you can make it permanent by editing the app's Info.plist or creating a launch script.

5. **Clear all application data** (will reset your settings):
   ```bash
   rm -rf ~/Library/Application\ Support/CortexIDE
   rm -rf ~/Library/Caches/CortexIDE
   ```
   **Warning**: This will delete all your settings, extensions, and workspace data.

6. **Check for Electron/Chromium rendering issues**:
   ```bash
   /Applications/CortexIDE.app/Contents/MacOS/CortexIDE --disable-gpu-sandbox
   ```
   Or try:
   ```bash
   /Applications/CortexIDE.app/Contents/MacOS/CortexIDE --disable-software-rasterizer
   ```

7. **Verify the app bundle is complete**:
   ```bash
   # Check if the app bundle structure is correct
   ls -R /Applications/CortexIDE.app/Contents/Resources/app/out | head -20
   ```
   You should see directories like `vs`, `main.js`, etc.

8. **Check macOS version compatibility**:
   - Ensure your macOS version is compatible with the Electron version used
   - Some older macOS versions may have rendering issues

9. **If using a custom build**, verify the build completed successfully:
   - Check build logs for any errors during the `minify-vscode` step
   - Ensure `workbench.html` was generated and copied to the app bundle
   - Rebuild if necessary

10. **Check for conflicting software**:
    - Some security software or screen recording apps can interfere with Electron rendering
    - Temporarily disable them to test

11. **Window not being created (processes running but no window)**:
    - This indicates the window creation code in the main process may be failing
    - Check if window bounds are invalid (0x0 or off-screen)
    - Verify the main process is calling `window.show()` or `window.showInactive()`
    - Check if the window is being created but immediately hidden
    - This may require a patch to the cortexide source code to ensure window visibility
    - Try resetting window state:
      ```bash
      defaults delete com.cortexide.code 2>/dev/null || true
      rm -rf ~/Library/Application\ Support/CortexIDE/User/workspaceStorage
      ```

If none of these solutions work, check the build logs and ensure the build completed successfully, particularly the minification and packaging steps. If the window is not being created at all (processes run but no window appears), this may require a code fix in the cortexide source repository to ensure the Electron BrowserWindow is properly shown on macOS.
