# zeron notification sounds

Copied verbatim from the Rust app (`zeron/crates/ui/assets/sounds/`, zeron `9e1a111`).
Original synthesized cues (Python standard library, rounded pressure pulses, no
external samples — see zeron `docs/sound-design/README.md` and
`scripts/generate-notification-sounds.py`). License: MIT, `../LICENSE.zeron`.

| File | Cue | Trigger (zeron `sound.rs`) |
| --- | --- | --- |
| `done.wav` | completion, settling rounded pair | an agent turn completed |
| `request.wav` | agent question, rising rounded pair | the agent waits on input |
| `attention.wav` | failure / durable disconnection, downward pair | a run failed, or connectivity went `Offline`/`Reconnecting` |
| `appshot.wav` | soft shutter + chime | Appshot capture confirmation (Appshots are not ported yet; kept for parity) |

The app embeds `done`, `request` and `attention` through the `zeron_sounds` module
(build.zig `addZeronLifecycle`).
