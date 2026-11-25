# ftoons for the browser

**On Windows**, double-click `Launch_WEB.bat` in this folder and keep its console open while playing. It starts a local server and opens `http://127.0.0.1:8061/` in your browser. Use the same address on later visits to reuse your imported files.

**On a website**, serve the files beside `index.html` together on an HTTPS static host. Serve `.wasm` with the MIME type `application/wasm`. You can mount the folder at the site root or under a subdirectory. The Windows launcher and its `local/` folder are optional for hosting. For local use on another operating system, serve this directory over HTTP on localhost.

## Import your game

1. In **DOS game**, choose your DOS installation ZIP, or select `TOONS.EXE`, `RESOURCE.001`, and `ADL.DRV` together.
2. In **Windows game**, optionally choose the Windows installation ZIP, its loose files, or the original disc. For the full mixed-mode soundtrack select the CUE and its companion BIN together. A data-only ISO can supply the Windows game data and intros.
3. Select **Import and play**. The build includes the game engine and decoders. Your browser reads the files locally and keeps the imported game data in this site's IndexedDB storage. The next visit in the same browser profile and at the same site can go straight into the game. Clearing site data or using a different browser profile requires a fresh import.

## Save and resume

**Save game** downloads a `.ftsave` file containing the current level and your gadget arrangement. **Load game** lets you choose that file later. These saves also work with the Windows production player. For levels from the optional Windows pack, import that pack on the device where you resume.
