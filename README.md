# Pip

A little sprout-headed pet that lives on your Mac desktop. Pip floats above your windows, has moods, reacts when you pat it or carry it around, and talks back when you talk to it.

![Pip greeting you, typing on a laptop, thinking, celebrating and feeling sad](docs/pip.png)

## What Pip does

- **Lives on top of everything.** Pip floats above every app and on every Space. Clicks around it go straight through to the windows underneath.
- **Has feelings.** Pip is drawn live, not from canned animations: springs and physics move its body, eyes, brows, mouth, arms and leaves. It has 16 emotions, from happy and curious to bored, sleepy and sad.
- **Gets up to things.** Left alone, Pip looks around, hops, hums, stretches, yawns and eventually falls asleep.
- **Notices you.** Its eyes follow your pointer, and hovering makes it blush. Click to pat it (three quick pats make it jump); drag it and it dangles, then lands with a puff of dust.
- **Talks.** Press **⌃⌥P** (Control-Option-P) anywhere and speak. Pip listens, then answers in its speech bubble and out loud in a small, high pet voice.
- **Does things for you.** Pip can read files, run commands and use your connected services, like Jira, Confluence or email. It always asks first before running a command, changing a file or sending anything.
- **Watches your Claude Code sessions.** Optionally, every Claude Code session reports to Pip, so it shows the one that needs you and can tell you what any of them is doing.

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

Pip answers through the [Claude Code](https://claude.com/claude-code) command-line tool, using your own Claude login (no API key). It gets Claude Code's tools and your claude.ai connectors. Install it and sign in once:

```bash
claude auth login
```

The first time you press ⌃⌥P, macOS asks to let Pip use the microphone and speech recognition. Speech is turned into text on your Mac when macOS supports it.

Pip listens and speaks in your Mac's language.

## What Pip may do

**Computer Access** in Pip's menu sets how much it can do:

| Setting | Pip can |
|---|---|
| Just Chat | Only talk. No files, commands or connectors. |
| Read Files Only | Read files, search, and look things up in connected services. |
| Do Things, Ask Me First (default) | Also run commands, change files and act through connectors, but only after you say yes. |

When Pip wants to do something, its bubble shows exactly what (the command, the file, or the email or Jira change) with **Allow** and **Deny** buttons, and Pip asks out loud. Click a button, or press ⌃⌥P and say "yes" or "no". Anything you don't answer within two minutes is denied, and **Stop What Pip Is Doing** in the menu cancels a task.

Connectors are the ones on your claude.ai account. A connector that shows as needing authorization has to be reconnected in your claude.ai connector settings first.

## Watching your Claude Code sessions

Turn on **Watch All Claude Sessions** in Pip's menu. Pip then adds a small hook to `~/.claude/settings.json`, keeping a backup at `~/.claude/settings.json.pip-backup`, so every Claude Code session, in the terminal or the desktop app, reports to Pip. Pip then:

- shows the session that needs you most, with its project name in the bubble,
- lists every session and its state in the menu,
- can read a session's history when you ask what it's doing.

Turning the switch off removes the hook again. Regular claude.ai chats don't run hooks, so Pip only sees Claude Code sessions.

## Using Pip

- **Move:** drag Pip anywhere, right up to the menu bar. It remembers the spot.
- **Pat:** click Pip.
- **Talk:** press ⌃⌥P, speak, then pause. Press ⌃⌥P again to stop early.
- **Menu:** right-click Pip, or click the Pip icon in the menu bar, for:
  - Show or hide Pip
  - Move Pip to the corner, for when it's lost off-screen
  - Talk to Pip and Pat Pip
  - Speak Answers, Pet Voice and Open at Login switches
  - Computer Access and Watch All Claude Sessions
  - Your Claude Code sessions and what each is doing
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

If you turned on **Watch All Claude Sessions**, turn it off first. Then right-click Pip, choose **Quit Pip**, and run:

```bash
rm -rf ~/Applications/Pip.app ~/.claude/pip-pet
```

If Pip is still listed in System Settings → General → Login Items, remove it there.

## License

[MIT](LICENSE)
