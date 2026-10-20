# Style

Conventions for anything written in this repository.

## Dashes

**Do not use em-dashes or en-dashes.** Neither character belongs in this
repository.

| Character | Codepoint | Write this instead |
|---|---|---|
| em-dash | `U+2014` | `--` (two hyphens) |
| en-dash | `U+2013` | `-` (one hyphen) |

So `a clause -- like this one -- reads that way`, and a range is `1-8 September`.

The characters are not typeable on a normal keyboard, so text containing them
cannot be edited the way it was written, and `--` is what the Terraform
comments already use.

This file names the rule by codepoint rather than demonstrating it, so a search
for the literal characters returns only violations. `make check-dashes` runs it:

```sh
git ls-files -z | xargs -0 grep -nIP '\x{2014}|\x{2013}'
```

There are no exclusions. If one turns up, raise it with the user.
