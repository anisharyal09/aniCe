# Working in aniCe

Before making changes:

1. Read [.agents/RULES.md](.agents/RULES.md).
2. Read [ARCHITECTURE.md](ARCHITECTURE.md) and applicable human documentation under `docs/`.
3. When present locally, read `.agents/CONTEXT.md`, `.agents/RULES2.md` and `.agents/STATE.md`; read `.agents/NOTES.md` where relevant. These ignored files are optional in other checkouts.
4. Inspect relevant contracts under `protocol/` and existing code before introducing changes.

For any UI or frontend task, read [docs/design/DESIGN.md](docs/design/DESIGN.md) before writing code.

Human documentation records product and architecture intent. `protocol/` owns communication contracts. `.agents/RULES.md` provides operational coding constraints.

## Git commit authorization

Do not create Git commits unless the user gives an explicit, unambiguous instruction to perform the commit. Questions, suggestions, commit-message discussions, and statements such as "good to go" or "looks good" are not authorization. If intent is ambiguous, ask for explicit authorization and leave changes uncommitted.

Authorization applies only to the specified changes; it is not ongoing authorization for later commits. Do not amend existing commits unless explicitly instructed.
