# Recovery and startup checks

`make test` checks same-device recovery decisions, sleep/wake intent, manual-stop cancellation, permission loss, startup opt-in, stale-work invalidation, audio metering, and localization. `make release` additionally builds arm64/x86_64 and verifies the app signature and disk image.

Hardware and OS integration still need these manual checks on the installed app:

| Action | Expected result |
| --- | --- |
| Start keep-alive, then sleep and wake the Mac | Capture pauses, then resumes on the same microphone. |
| Disconnect the selected Bluetooth mic | Menu shows the saved device name, Disconnected, and Waiting for the same microphone. |
| Connect a different microphone while waiting for a disconnected mic | Keep waiting for the original mic unless another input is manually selected in the app. |
| Reconnect the selected microphone | Capture resumes; the live meter returns. |
| Stop while waiting, then reconnect or wake | Capture stays off. |
| Stay silent while capture is active | Meter settles; status remains Audio stream healthy. |
| Quit and reopen with Restore off | Capture stays off. |
| Turn Restore on, start capture, quit and reopen | Capture resumes, or waits if the same device is absent. |
| Turn Restore on, stop capture, quit and reopen | Capture stays off. |
| Enable Launch at login from Applications | Item is checked if approved, or shows approval required with a link to Login Items settings. |
| Disable Launch at login | Registration is removed; changing this option does not start/stop capture. |
| Login with Launch enabled and Restore disabled | App opens without activating the microphone. |
| Revoke microphone permission | Recovery waits for permission; no background permission prompt or device fallback. |

Quit always releases capture. Restore remembers user intent, including while waiting for a disconnected device. System sleep, Bluetooth interruption, and audio failures do not change that intent. Explicit Stop does.

Login-item registration and real sleep/Bluetooth recovery are not exercised by automated checks. They require user interaction/hardware and must not be described as verified merely because compilation passes. Intel builds are checked structurally; Intel hardware is not available in the current validation environment.

## System input switching

- The submenu checkmark reflects the macOS default input; the header separately shows the keep-alive device.
- Select a microphone while stopped: System Settings must show that input, without starting capture.
- Select a microphone during capture, including rapid consecutive selections: capture must move to the last selected input and old capture work must not resume.
- Change input in System Settings while the keep-alive device is connected: the app follows within two seconds (also on menu opening).
- Disconnect the active device: automatic system fallback must not activate another microphone. Reconnection resumes the original keep-alive target; the two header rows can correctly differ until manually synchronized.
- Input-switch failures leave capture intent unchanged and show a localized error.
- Output routing must remain unchanged.

Local validation: CoreAudio switched from Wireless Mic Rx to BlackHole 2ch and back; default output was unchanged. An invalid UID was rejected without changing input. Policy tests cover external route changes and disconnect/sleep protection. Actual Bluetooth transitions and rapid live-capture switching still require hardware/UI checks.

## Device menu interaction

- Successful manual switches increment persistent per-UID usage; failed or repeated selections of the current device do not. Frequency sorts first, then recency, then name/UID.
- Opening the submenu applies the latest ranking. While open, order stays fixed and checkmarks update in place; disconnected rows become disabled. Reopen to refresh the device list.
- Clicking a device must keep the menu visible. Clicking outside or Escape dismisses it.
- `make test` checks ranking, recency ties, persistence and deterministic ordering.

Installed-app UI check: selected BlackHole 2ch and then Wireless Mic Rx through the submenu buttons; the submenu remained accessible after each selection and the system-input header updated. Reopening placed Wireless Mic Rx first and BlackHole second. Original Wireless Mic Rx input was restored.

## Menu bar status

Five states distinguish a disconnected target, connected/unmonitored input, pending keep-alive, healthy low-level input, and healthy audible input. The shield is shown only with a healthy stream, including silence. Input is not sampled while keep-alive is off; no claim is made about other apps recording or system mute. `make test` covers all five mappings and renders native icon previews. Check visibility in light/dark menu bars and watch the meter with real microphone audio.

Compact icon: standby uses 16 pt and does not sample audio; other states use 26 pt for a small badge. Healthy input fills the microphone capsule vertically instead of using separate bars. Confirm stopping releases capture and removes the live fill.

## Persistent control panel

`make test` includes missing-driver/available-driver states, disabled controls without an input, source selection, gain selection and inline help. The missing-driver state is simulated; no installed driver is removed for this test.

On the installed app, check that source selection, gain changes, keep-alive/boost switches, startup check tiles, check-again and inline help all keep the popover visible. Test that clicking outside and Escape close it. Do not exercise login registration merely to test persistence. The application-defined popover closes only on outside mouse clicks, Escape, the status button or app exit; internal controls and focus changes do not dismiss it. macOS 26+ uses NSGlassEffectView; macOS 14–15 fallback is compile-checked but not exercised on this Mac.

Device tiles: two columns, selected border/checkmark, two-line names, frequency order refreshed only on panel opening. Tests cover stable order during selection and refreshed order on next opening. Device-area scrolling is capped at three rows.

Physical/virtual ordering: use AVCaptureDevice transport type (virtual/aggregate) rather than display-name guesses. Physical devices precede a collapsed virtual-device group. Unit tests verify physical-first ordering even if a virtual device arrives first, plus explicit expansion. Device tiles use native NSGlassEffectView surfaces on macOS 26+, with interactive glass enabled on macOS 27+.

Verify the panel stays 380 points wide when expanding virtual devices and long inline help. Startup settings must remain visible without a disclosure; their check states follow login/restore preferences.

Verify three linked states: off, keep-alive only, and keep-alive with boost. Enabling boost enables keep-alive; disabling boost preserves keep-alive; disabling keep-alive disables both and releases capture. Check the persistent switch-back notice after stopping boost. Healthy boost displays a bold plus above the shield; pending/failed capture must not show a healthy boost badge.

### Bluetooth output-route recovery

Start physical capture before binding the enhancement engine to BlackHole. A deferred output route/format change should stop and rebind only that engine, preserving the physical capture session. Check the destination after engine start as well as before scheduling audio; do not change system default routes. The retry status must remain visible while capture is healthy but enhancement output is unavailable.

`make test-enhancement-loopback` now exercises three stopped-engine route invalidations for each 48 kHz, 24 kHz and 16 kHz source, confirms audio returns through BlackHole, and verifies default input/output remain unchanged. The temporary alternate route never receives queued test audio. The injection helper is compiled only with `ROUTING_TESTS`.

Hardware check: with the lid closed and AirPods connected, enable boost and observe at least 20 seconds. Confirm healthy boost and dictation input on BlackHole. Repeat after reconnecting AirPods; this check is separate from the synthetic loopback test.

On the closed-lid AirPods reproduction, after binding BlackHole the engine output node's client `inputFormat` remained mono/24 kHz while its hardware `outputFormat` was stereo/48 kHz. Configure the graph from `outputFormat`; checking the stale client channel count rejects a valid BlackHole route. Run the loopback regression while AirPods input is active to cover that initial state.

2026-11-25: with the lid closed and AirPods capture active, loopback passed at 16/24/48 kHz, including three output-route invalidations per rate. The hardware format differed from the stale client format (stereo/48 kHz versus mono/24 kHz). This verifies routing and resampling, not dictation accuracy.

Virtual-device disclosure uses a header above its own grid: down-circle when collapsed, up-circle when expanded. Check click and keyboard activation, hidden/empty groups, automatic expansion when selecting a virtual device externally, fixed panel width, and that the popover stays open.
