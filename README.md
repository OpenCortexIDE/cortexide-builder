# CortexIDE Builder

This is a fork of VSCodium, which has a nice build pipeline that we're using for CortexIDE. Big thanks to the CodeStory team for inspiring this.

The purpose of this VSCodium fork is to run [Github Actions](https://github.com//OpenCortexIDE/cortexide-builder/actions). These actions build all the CortexIDE assets (.dmg, .zip, etc), store these binaries on a release in [`OpenCortexIDE/cortexide-binaries`](https://github.com/OpenCortexIDE/cortexide-binaries), and then set the latest version in a text file on [`OpenCortexIDE/cortexide-versions`](https://github.com/OpenCortexIDE/cortexide-versions) so CortexIDE knows how to update to the latest version.

The  `.patch` files from VSCodium get rid of telemetry in CortexIDE (the core purpose of VSCodium) and change VSCode's auto-update logic so updates are checked against `cortexide` and not `vscode` (we just had to swap out a few URLs). These changes described by the `.patch` files are applied to the CortexIDE source during the workflow run, and they're almost entirely straight from VSCodium, minus a few renames to CortexIDE.

## Notes

- For an extensive list of all the places we edited inside of this VSCodium fork, search "CortexIDE" and "cortexide". We also deleted some workflows we're not using in this VSCodium fork (insider-* and stable-spearhead).

- The workflow that builds CortexIDE for Mac is called `stable-macos.yml`. We added some comments so you can understand what's going on. Almost all the code is straight from VSCodium. The Linux and Windows files are very similar.

- If you want to build and compile CortexIDE yourself, you just need to fork this repo and run the GitHub Workflows. If you want to handle auto updates too, just search for caps-sensitive "CortexIDE" and "cortexide" and replace them with your own repo.

## Troubleshooting

If you encounter issues after building and installing CortexIDE:

- **macOS blank screen**: Run `./fix_macos_blank_screen.sh` to diagnose and fix GPU cache issues
- See [docs/troubleshooting.md](docs/troubleshooting.md) for detailed troubleshooting steps

## Rebasing
- We often need to rebase `cortexide` and `cortexide-builder` onto `vscode` and `vscodium` to keep our build pipeline working when deprecations happen, but this is pretty easy. All the changes we made in `cortexide/` are commented with the caps-sensitive word "CortexIDE" (except our images, which need to be done manually), so rebasing just involves copying the `vscode/` repo and searching "CortexIDE" to re-make all our changes. The same exact thing holds for copying the `vscodium/` repo onto this repo and searching "CortexIDE" and "cortexide" to keep our changes. Just make sure the vscode and vscodium versions align.
