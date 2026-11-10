# DAO

Things I've learned from writing software, written down as prompts for coding agents.

Each file in `prompts/` covers one topic. Copy the ones you want into your project's `CLAUDE.md`, `.cursorrules`, or system prompt. They stack fine.

## Prompts

- [backend-design.md](prompts/backend-design.md) — build only what's asked for, list the facts first and keep raw apart from derived, then place every piece of code in one of three layers: core talks to infrastructure, operations apply business rules, workflows assemble use cases.
- [orchestrator.md](prompts/orchestrator.md) — run the main session on the strongest model as a pure orchestrator: it splits the task, hands every piece to a subagent on the cheapest model and effort that can do it, takes back only short reports, and stops before its context or the weekly usage limit runs out.

## License

MIT.
