# Changelog

All notable changes to this project are documented in this file. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This is a Bash script with no package manifest, so versioning is git-tag
only. This is the first tagged release.

## [0.2.0] - 2026-07-06

### Added

- CI workflow (`.github/workflows/ci.yml`) running the real test suite
  (`bash tests/run.sh`) on every push and pull request — this repo
  previously had no CI at all.
- CHANGELOG.md (this file).
- `flock`-based concurrency serialization on all commit call sites
  (`send`, `tick`, `remember`, `think`, `decide`), and a registry-level
  lock for `spawn`/`broadcast`/`fleet` to eliminate check-then-act races
  on agent creation and registry updates.
- `tests/concurrency.sh` covering concurrent send/tick/spawn and mixed
  send/tick scenarios — reproduces the original `.git/index.lock` race
  crashes and confirms they no longer occur.

### Fixed

- A TOCTOU race in `tick_agent`: scan inbox → process → update tick
  counter → commit is now one locked atomic section, rather than several
  separate operations that could interleave under concurrent access.

## [0.1.0] - 2026-06-06

Initial multi-agent orchestrator: each agent is a git repository, agents
communicate by committing files to each other's `inbox/`, memories are
stored as git tags, and coordination happens through merge commits.

### Added

- `orchestrator.sh` with `spawn`, `send`, `tick`, `remember`, `recall`,
  `think`/`decide` (thought branches), `broadcast`, and `fleet` commands.
- MIT license, README documenting the command reference and repository
  layout of an agent.
