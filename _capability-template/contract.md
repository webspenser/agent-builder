# <Capability> contract

What this capability does for the agent, in one paragraph. Skills and
sub-agent contracts call these operations by name — never a provider's
tools.

## Operations

| Operation | Arguments | Returns | On failure |
|---|---|---|---|
| `example_operation` | `argument` | what it returns | what it rejects |

## Invariants

An adapter's `guard.yaml` lists in `covers` the invariants it enforces
by mechanism; the rest rely on the agent's instructions.

- `example_invariant` — a rule every adapter must uphold. Name one
  `no_send` if the capability must never send a message to anyone.
