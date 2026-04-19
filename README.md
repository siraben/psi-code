# psi coding agent

`psi` is a rewrite of `pi` in C89 with Scheme as its extension language.

The immediate goal is not feature parity with `pi-mono`. The goal is to keep
the same minimal harness philosophy while rebuilding the core around a simpler
runtime:

- C89 host runtime
- Chibi-Scheme as the embedded extension language
- Nix flake based development and packaging
- A small, explicit core that grows from a working vertical slice

## Current status

This repository currently contains:

- an architecture document in [docs/architecture.md](docs/architecture.md)
- a Nix flake that builds Chibi-Scheme and `psi`
- a C89 project scaffold
- a minimal embedded Scheme runtime
- a working print/eval slice for proving the host <-> Scheme boundary

It does not yet contain the full `pi` session model, TUI, RPC protocol, or
compaction system. Those are described in the architecture document and will be
built incrementally.

## Quick start

Build with Nix:

```bash
nix build
./result/bin/psi --help
./result/bin/psi --eval '(+ 1 2 3)'
./result/bin/psi --print 'hello'
```

For local development:

```bash
nix develop
make
./build/psi --eval '(+ 1 2 3)'
./build/psi --print 'hello'
```

## Layout

- `docs/architecture.md`: planned runtime architecture
- `include/psi/`: public project headers
- `src/`: host runtime implementation
- `scheme/`: Scheme bootstrap and future host libraries
- `tests/`: smoke tests

