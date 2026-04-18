# For Hidden Devs

This project now centers on one submission file:

- `src/server/init.server.luau`

That single server script builds the full Reactor Relay demo at runtime. It creates the arena,
launch pads, relay stations, checkpoints, hazards, bridges, score system, and the timed
stabilization loop without relying on helper modules.

## Build The Demo Place

```bash
rojo build -o "For Hidden Devs Demo.rbxlx"
```

Open the generated `.rbxlx` in Roblox Studio to test the game. The arena is generated on the
server when the place starts.

## Submission Notes

- Publish a direct GitHub file link to `src/server/init.server.luau`.
- Do not submit the repository root link.
- Credit yourself in the Roblox place description, in-game, or through an external page linked by the place description.
