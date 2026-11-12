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
