# CLAUDE.md

## Writing style

Read `STYLE.md` before writing prose, comments or commit messages here.

The rule that gets broken most: **no em-dashes (U+2014) and no en-dashes
(U+2013), anywhere in the repository.** Write `--` and `-` instead. `make
check-dashes` enforces it.

## Generic by design

macaw serves any AWS Organization. Nothing committed may name a particular
organization's accounts, aliases, colors, IDs, SCPs or profiles: all of that
lives in the gitignored `terraform.tfvars` (or the file `VARS` points at), and
the per-account Terraform is generated from it into the gitignored
`accounts.gen.tf` by `scripts/generate.sh`. Examples use placeholder IDs
(`111111111111`, AWS's `123456789012`) and generic names.

Per-account Terraform belongs in the generator, never hand-written in a `.tf`
file. Changing the shape of `var.accounts` means changing `variables.tf`,
`scripts/generate.sh`, the teardown parser and `terraform.tfvars.example`
together.

## Tests

`make test` runs `modules/scp-visibility/tests` offline, then checks that the
teardown script reads the same accounts from the settings file as Terraform
does. Any change to the SCP rules or `service_map.tf` needs a case there.
Compare lists through `jsonencode` in assertions: an output is a list, a
bracketed literal is a tuple, and `==` between them is false even when the
elements match.

## Teardown

`scripts/teardown.sh` is the way out when a customization gets in the way, so
it must keep working when Terraform does not. Keep it on the AWS CLI, jq and a
grep/sed parse of the settings file: no `terraform` commands, and nothing that
evaluates the configuration, reads state or depends on `accounts.gen.tf`.
`scripts/check-teardown-parse.sh` (run by `make test`) is what keeps that
parse in step with Terraform's.

## Least privilege

macaw is meant to run as `bootstrap/`'s identities: a management-account
permission set and a `macaw-console` role in each member account, both able to
change console settings and nothing more. Anything new that macaw calls in AWS
needs adding to both policies in `bootstrap/main.tf` (and to the session policy
in `providers.tf` if it runs in a member account), or it fails with access
denied for everyone using the bootstrap. Never widen either toward
administrator access to make something work.
