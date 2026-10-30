# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[Report a vulnerability](https://github.com/crossecute/forge-attest/security/advisories/new).
Please do not open a public issue, pull request or discussion for it.

A useful report names the claim, producer output, Safe Transaction Service response
or environment that triggers the problem, and what happens: for example a run that
prints `ATTESTED` when it should not, or a response that runs code on the machine
doing the check. A reproduction against `test/shell/run.sh` or a minimal claim
helps most.

## Supported versions

Fixes go into the latest release. The `v1` tag follows the latest `v1.x.y` release,
but the README recommends pinning the action by commit SHA. If you do, update the
pin to receive a fix.

## Scope

In scope is anything that makes forge-attest report a verdict it should not, or
that lets an input it treats as untrusted affect more than the verdict. The
untrusted inputs are the producer's output, Safe Transaction Service responses, and
the claim file when a fork pull request controls it.

Out of scope, because they are the design (see the README's
[Threat model](README.md#threat-model)):

- `producer_setup` and the producer's Forge script run as code. Whoever can edit
  the claim or the producer repo can run code on the machine doing the check.
- A producer commit that you pinned and that builds a harmful transaction. The tool
  proves where a transaction came from, not that it is safe.

`lib/safe_hashes.sh` is vendored from
[safe-tx-hashes-util](https://github.com/pcaversaccio/safe-tx-hashes-util). Report a
flaw in that script to its maintainer as well. A flaw in how forge-attest calls it
or reads its output belongs here.
