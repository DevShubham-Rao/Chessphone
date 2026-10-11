# Controls and feedback update

## New controls

Open Vibration & Audio Settings:
- Presets: type a name and Save. Tap a saved name to load it. Its menu lets you rename, replace its pattern with the current pattern, or delete it.
- Vibration controls: independently enable move vibrations and button feedback, or use All vibrations off. That master switch also mutes invalid-move vibrations, without muting speech.
- Invalid-move feedback: adjust each buzz duration (0.05–3 seconds), strength (0.1–1), buzz count (1–8), and gap (0–3 seconds). Enable spoken errors independently of spoken moves. Test the feedback with the supplied button.
- Volume controls: Reconnect volume controls reactivates and recenters hardware input.

Count, Confirm, and Replay are on the game screen and call the existing input/replay actions. Count always enters manual taps, even if the optional scanning mode is enabled. These controls remain usable when iOS misses physical volume changes.

All new settings and custom presets persist between app launches. The existing current pattern is preserved.

## Volume reliability changes

Direction is read from consecutive observed volume values rather than an assumed 50% baseline. Pending programmatic resets are filtered, slider actions are sent through a mounted MPVolumeView, and recovery is retried after view mounting, foregrounding, audio interruptions, route changes, and audio-service resets. Category-change notifications are ignored to avoid triggering recovery recursively.

Practice mode mounts its own volume control and restores game callbacks when closed. The underlying input handler stays alive while practice covers the root screen. Volume input is ignored while the app is inactive.

This remains best-effort volume-state observation, not a dedicated iOS hardware-button API. Hardware presses at a volume boundary cannot be observed if iOS rejects the midpoint reset. Use the on-screen controls in that case.

## Validation for this update

- All 25 Swift files passed a tree-sitter Swift syntax parse.
- project.yml passed YAML parsing, including the source directory that includes FeedbackSettings.swift.
- Existing archive entries were preserved; the changes are limited to the controls/feedback implementation, plus this documentation.
- ZIP entry contents and integrity were checked against the working tree.

An Xcode compile/link and real-device verification were not available in this environment. Syntax validation does not replace compilation.

## iPhone checks after building

1. Save two presets; load, rename, replace, and delete one. Relaunch and confirm settings remain.
2. Test each vibration toggle and All vibrations off, including an invalid move.
3. Customize invalid-move duration, strength, count, gap, and speech; test and enter an illegal move.
4. Enter the same move with physical buttons and then with Count/Confirm. Test Replay.
5. Test alternating and rapid volume presses, background/foreground, opening/closing practice, Siri/audio interruptions, and headphone changes. Use Reconnect if needed.
