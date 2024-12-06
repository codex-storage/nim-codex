# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To build a Codex you can use:
```sh
nix build '.?submodules=1#codex'
```
The `?submodules=1` part should eventually not be necessary.
For more details see:
https://github.com/NixOS/nix/issues/4423

It can be also done without even cloning the repo:
```sh
nix build 'github:codex-storage/nim-codex?submodules=1'
```

## Running

```sh
nix run 'github:codex-storage/nim-codex?submodules=1'
```
