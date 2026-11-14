# Pip

A little sprout-headed pet that lives on your Mac desktop. Pip floats above your windows, has moods, reacts when you pat it or carry it around, and talks back when you talk to it.

![Pip greeting you, typing on a laptop, thinking, celebrating and feeling sad](docs/pip.png)

## What Pip does

- **Lives on top of everything.** Pip floats above every app and on every Space. Clicks around it go straight through to the windows underneath.
- **Has feelings.** Pip is drawn live, not from canned animations: springs and physics move its body, eyes, brows, mouth, arms and leaves. It has 16 emotions, from happy and curious to bored, sleepy and sad.
- **Gets up to things.** Left alone, Pip looks around, hops, hums, stretches, yawns and eventually falls asleep.
- **Notices you.** Its eyes follow your pointer, and hovering makes it blush. Click to pat it (three quick pats make it jump); drag it and it dangles, then lands with a puff of dust.
- **Talks.** Press **⌃⌥P** (Control-Option-P) anywhere and speak. Pip listens, then answers in its speech bubble and out loud in a small, high pet voice.

## Install

You need macOS 13 or later and Apple's Command Line Tools, which provide the Swift compiler:

```bash
xcode-select --install
```

Then build and open Pip:

```bash
git clone https://github.com/muradinfosec/pip-desktop-pet.git
cd pip-desktop-pet
./install.sh
```

That builds `Pip.app` into `~/Applications` on your own Mac and opens it. Pip adds itself to **Login Items** the first time it runs, so it's there every time you log in.

### Talking to Pip

Pip answers through the [Claude Code](https://claude.com/claude-code) command-line tool, using your own Claude login (no API key). Install it and sign in once:

```bash
claude auth login
```

The first time you press ⌃⌥P, macOS asks to let Pip use the microphone and speech recognition. Speech is turned into text on your Mac when macOS supports it.

Pip listens and speaks in your Mac's language.

## Using Pip

- **Move:** drag Pip anywhere. It remembers the spot.
- **Pat:** click Pip.
- **Talk:** press ⌃⌥P, speak, then pause. Press ⌃⌥P again to stop early.
- **Menu:** right-click Pip, or click the Pip icon in the menu bar, for:
  - Show or hide Pip
  - Move Pip to the corner, for when it's lost off-screen
  - Talk to Pip and Pat Pip
  - Speak Answers, Pet Voice and Open at Login switches
  - Quit Pip

## Telling Pip what you're doing (optional)

Pip watches `~/.claude/pip-pet/status.json`. Anything can write it (a script, a hook, an editor plugin), and Pip acts out what it says:

```json
{ "mood": "working", "activity": "read", "line": "Reading notes.md", "updatedAt": 1731600000000 }
```

| `mood` | What Pip does |
|---|---|
| `thinking` | Hand on chin, thought dots |
| `working` | Busy; `activity` picks a prop: `run`, `edit` or `write` (laptop), `read` (book), `search` or `web` (magnifying glass), `helper` (paper plane) |
| `waiting` | Waves with a "?" |
| `done` | Jumps with confetti, then idles |
| `oops` | Flinches, then looks sad |
| `sleeping` | Falls asleep |

`line` is what Pip says in its bubble.

## Uninstall

Right-click Pip and choose **Quit Pip**, then:

```bash
rm -rf ~/Applications/Pip.app ~/.claude/pip-pet
```

If Pip is still listed in System Settings → General → Login Items, remove it there.

## License

[MIT](LICENSE)
