# Samples

This directory holds only the examples the agent ships with: filled,
gold-standard artifacts written by the agent's author. The user's own
examples go in the instance's `context/samples/` (setup creates it; the
interview saves them there), and the agent reads those first. In plugin
mode this package folder is read-only.

Samples teach voice. This template ships none on purpose — a generic
sample would be copied into real output and nobody would notice it
happened.

Ship an example here only if it is right for every user of the agent.
Anything specific to one business belongs in that instance's
`context/samples/`.
