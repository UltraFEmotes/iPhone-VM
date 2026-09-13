# Native Windows build of Inferno

`inferno-windows-build.yaml` is the GitHub Actions workflow on the owner's fork
(https://github.com/UltraFEmotes/Inferno, branch `windows-build`). It builds Inferno with MSYS2/UCRT64.

- First success: run 34752054655 on 2026-09-13.
- Output: `qemu-system-aarch64.exe` with the t8030 and s8000 machines, `qemu-system-x86_64.exe` with WHPX, `qemu-img.exe`, 46 DLLs and the firmware files.
- Not yet run on real Windows. `out/InfernoNativeTest.zip` is the smoke test for the friend.
- To rebuild, push to that branch or run `gh workflow run windows.yaml -R UltraFEmotes/Inferno --ref windows-build`.
