# pi-stuff

Pi package scaffold for extensions, skills, prompts, and themes.

## Layout

```
extensions/   # TypeScript extensions
skills/       # Agent skills (SKILL.md)
prompts/      # Prompt templates (.md)
themes/       # Themes (.json)
```

## Load in pi

```bash
pi install /absolute/path/to/pi-stuff
# or project-local
pi install -l /absolute/path/to/pi-stuff
```

Then run `/reload` in pi after changes.

## Credits

Some of the extensions in this repository are copied, inspired, or modified from [mitsuhiko/agent-stuff](https://github.com/mitsuhiko/agent-stuff) (Apache License 2.0).
