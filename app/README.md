# app — Flutter UI (M2 / M3)

The cross-platform UI. One Dart codebase binding `rewcore` through `dart:ffi`
(`core/ffi/rewcore_ffi.h`) and talking to the native audio/USB plugins via platform
channels.

## Planned structure

- **FFI bindings** to `rew_generate_sweep`, `rew_measure_fr`, `rew_fit_peq_flat`
  (generate with `ffigen` against `core/ffi/rewcore_ffi.h`).
- **Guided wizard** (M3): `level → crossovers → EQ → verify`, project-based
  (save/reopen a car). Each per-driver step prompts the user to solo the relevant
  channel in the DSP's own app before measuring.
- **Live graphs**: frequency-response and correction curves (`fl_chart` or a custom
  `CustomPainter` for log-frequency axes).
- **"DSP entry" sheets**: the wizard's output — exact PEQ bands (freq/gain/Q) and
  crossover points/slopes to type into the DSP app, with a checklist.

Kept empty until M2 (the native audio path is proven in Spike #0 first). No DSP logic
lives here — it all calls into `rewcore`.
