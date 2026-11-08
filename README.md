<p align="center">
  <img src="assets/logo.png" alt="Mic KeepAlive logo" width="128" />
</p>

<h2 align="center">macos-mic-keepalive</h2>

<p align="center">
  <strong>Keep your mic awake. Keep your coding flow.</strong><br/>
  <sub>Microphone keep-alive for voice-driven vibe coding on macOS.</sub>
</p>

<p align="center">
  macOS 14+ · Native Swift · English / 中文<br/>
  <a href="#why">Why</a> · <a href="#how">How</a> · <a href="#what-you-get">What you get</a>
</p>

---

# Why

Vibe coding by voice? Your coding agent needs the start of your prompt, too.

With your MacBook closed and an external display connected, a Bluetooth mic may be your only practical input. After sitting idle, it can take seconds to wake—cutting off your first words. Keep it ready for your next instruction.

# How

Keeps an audio stream open on your chosen microphone. **No recordings. No uploads.**

```sh
make run
```

Requires Xcode Command Line Tools. Allow microphone access, choose your mic, and start keep-alive. Select the same mic in the dictation app you use to talk to your coding agent.

# What you get

- **Stay in flow:** reduce mic wake-up delays between spoken coding instructions.
- **Bluetooth-first:** use AirPods or a DJI Bluetooth mic. USB and other macOS inputs work too.
- **Live levels:** a small animated meter, no menu bar text.
- **Your language:** follows macOS—English or Chinese.
- **Your control:** stop anytime; disconnecting stops capture. No auto-start.

<sub>Bluetooth audio quality and battery life may be affected. Device results vary; DJI-specific behavior is not yet verified. This does not fix transcription or network delays.</sub>

<sub>Development: <code>make test</code> · <code>make clean</code></sub>
