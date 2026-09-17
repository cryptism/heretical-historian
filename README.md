# Heretical Historian

A history generator for occult societies. Watch the quintillion-fold truths be born, commit wonders, battle, love, and die.

Essentially an event log below a basic constraint solver and free variable-binder, and below that an engine of esoteric events befalling randomly generated occult societies, each with their own quirks, and the ability to progressively reveal events both as they occur and in the past, post-hoc.

Website [here](https://heretical-historian.pages.dev)!

## Usage

```bash
cabal build
cabal run historian -- --seed 42 --steps 14
cabal test
```
