# zeron assets

Static assets of the zeron desktop client, copied from the Rust app
(`zeron/crates/ui/assets/`) and embedded at compile time through the generated
`apps/zeron/src/assets.zig` (regenerate with `scripts/gen_assets.py` after
changing anything here; the build exposes it as the `zeron_assets` module).

| Path | Contents | Source | License |
| --- | --- | --- | --- |
| `fonts/` | Geist and Geist Mono static TTFs, 8 faces each (Regular, Italic, Medium, MediumItalic, SemiBold, SemiBoldItalic, Bold, BoldItalic) | `vercel/geist-font` release `v1.7.2` | SIL OFL 1.1, `fonts/licenses/Geist-OFL.txt` |
| `icons/` | 117 control icons (SVG, `currentColor`) | Solar Icons (Linear) by 480 Design, plus zeron's own glyphs and harness brand marks | CC BY 4.0 / MIT, see `icons/ATTRIBUTION.md` |
| `file-icons/files`, `file-icons/folders` | 250 file and 105 folder icons | `miguelsolorio/vscode-symbols` @ `296ef1b62287fb2315cb5651e552e09e8c8e1de8` | MIT, `file-icons/LICENSE.symbols` |
| `file-icons/file-icons.json` | VS Code file-icon theme manifest for the above | same (via zeron `crates/ui/src/file-icons.json`) | MIT |
| `sounds/` | Session chimes: `done.wav`, `request.wav`, `attention.wav`, `appshot.wav` (see `sounds/README.md`) | zeron `crates/ui/assets/sounds` (zeron's own synthesized cues) | MIT, `LICENSE.zeron` |
| `LICENSE.zeron` | zeron's own license (covers zeron-drawn glyphs) | zeron repository | MIT |

Full notices: `THIRD_PARTY_NOTICES.md`. The bundled theme palettes (data, not
files) carry their own notices there as well.
