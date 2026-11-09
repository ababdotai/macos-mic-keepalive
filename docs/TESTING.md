# Recovery and startup checks

`make test` checks same-device recovery decisions, sleep/wake intent, manual-stop cancellation, permission loss, startup opt-in, stale-work invalidation, audio metering, and localization. `make release` additionally builds arm64/x86_64 and verifies the app signature and disk image.

Hardware and OS integration still need these manual checks on the installed app:

| Action | Expected result |
| --- | --- |
| Start keep-alive, then sleep and wake the Mac | Capture pauses, then resumes on the same microphone. |
| Disconnect the selected Bluetooth mic | Menu shows the saved device name, Disconnected, and Waiting for the same microphone. |
| Connect a different microphone | No switch and no capture on that device. |
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
