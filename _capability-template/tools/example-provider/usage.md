# <Capability> — <Provider> tool

Maps the contract (`../../contract.md`) onto <Provider>'s tools.
`provider:` below means the connected <Provider> server's tools,
whatever their prefix.

- `example_operation` — `provider:tool-name` with the arguments; what
  to check first, and when to refuse.

## Probe

Read-only calls setup makes when binding this tool, and what it
writes to `bindings/<capability>.md` in the instance.

1. `provider:whoami` — record the account or workspace name.
