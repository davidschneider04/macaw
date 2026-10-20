<p align="center">
  <img src="logo.svg" alt="macaw logo" width="160">
</p>

# macaw

**M**odular **A**djustable **C**onsole for **A**mazon **W**eb Services

macaw uses [AWS User Experience Customization](https://docs.aws.amazon.com/awsconsolehelpdocs/latest/gsg/uxc.html)
(UXC), through the Terraform AWS provider's `aws_uxc_account_customizations`
resource, to set three things in each account you list:

- **account color**, shown in the console navigation bar
- **visible Regions** in the Region selector
- **visible services** in console navigation

You choose each account's color. The visible Regions and services are
**derived from your organization's SCPs**, so each account's console shows what
the organization lets that account use, and follows the SCPs when they change.

Visibility is cosmetic. It hides nothing from the CLI, SDKs or APIs; the SCPs
it is read from are what enforce anything.

## Requirements

- An AWS Organization with all features enabled, using IAM Identity Center.
- An administrator profile for the management account, used once, to apply
  [the least-privilege setup](#least-privilege-setup). Day to day, macaw runs
  as the narrow permission set that setup creates.
- **SCPs that allow `uxc:*` in member accounts.** SCPs bind macaw's member
  role like any other principal. If your SCPs restrict services to a list, add
  `uxc:*` to it, or every member account fails at plan time with an explicit
  deny. See [SCPs and macaw](#scps-and-macaw).
- Terraform >= 1.9, the AWS CLI v2, `jq` and `bash`.

## Quick start

```sh
# Once, as an administrator of the management account:
aws cloudformation activate-organizations-access --region us-east-1 --profile <admin>
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
make bootstrap-init bootstrap-plan    # review
make bootstrap-apply                  # prints the profile to add next

# Then, as the macaw permission set:
cp terraform.tfvars.example terraform.tfvars   # describe your organization
make login        # aws sso login for the management profile
make init
make plan         # review: each account's color, Regions and services
make apply
make show         # what each account's console now reports
```

The color appears on the next console page load.

`make plan` prints one output per account with its resolved lists, and `make
hidden ACCOUNT=<alias>` lists just the services that account will hide. Review
that before the first apply: most organizations hide far more than they
expect.

## Configuration

`terraform.tfvars` is the whole of one organization's setup. Nothing else in
the repository names an account, a color or an ID.

```hcl
management_account_id = "111111111111"
management_profile    = "my-management-profile"

accounts = {
  management = {
    id                     = "111111111111"
    color                  = "red"
    extra_visible_services = ["support", "health-dashboard"]
  }
  production  = { id = "222222222222", color = "orange" }
  development = { id = "333333333333", color = "green" }
  sandbox     = { id = "444444444444", color = "yellow", derive_visibility = false }
}
```

| Setting | Meaning |
|---|---|
| `management_account_id` | The organization's management account. |
| `management_profile` | AWS CLI profile for it. |
| `member_role_name` | Role assumed in member accounts. Default `OrganizationAccountAccessRole`. |
| `accounts.<alias>.id` | The account. The alias names its module, its output and the `ACCOUNT=` argument of make targets. |
| `accounts.<alias>.color` | `none`, `red`, `darkBlue`, `lightBlue`, `green`, `yellow`, `orange`, `pink`, `purple` or `teal`. Default `none`. |
| `accounts.<alias>.derive_visibility` | `false` sets only the color and leaves Regions and services at the console default. Default `true`. |
| `accounts.<alias>.extra_visible_services` | Console service ids to show although no SCP allows them. `make services` lists valid ids. |

Accounts not listed are never touched. The management account is optional.

## Turning it off

If a customization gets in the way, put the console back first and work out why
afterwards:

```sh
make teardown                     # every listed account, after typing 'yes'
make teardown ACCOUNT=production  # one account
```

Each account is back to no color, every Region and every service within
seconds; reload open console tabs. It uses only the AWS CLI and `make login`,
not Terraform, so it works when a plan does not. It reads each account back
afterwards and names any it could not reset.

Nothing in macaw runs on its own, so a torn-down account stays at the defaults
until someone runs `make apply`. Terraform does not know about the teardown,
and the next `make plan` shows every customization being applied again. From
there:

- **To restore them:** fix whatever was wrong, then `make plan` and `make apply`.
- **To keep one account at the defaults:** remove it from `accounts` and apply.
  Terraform "destroys" it, which is a reset, and stops tracking it.
- **To keep all of them at the defaults:** `make destroy`. It needs Terraform
  working, which is why it is not the first step.

**Without this repository**, sign in to the account and use the console:
account menu > Account > Account display settings > None for the color, and
[Unified Settings](https://console.aws.amazon.com/settings/home) > Edit > All
for Regions and services. Or with the CLI, as that account:

```sh
aws uxc update-account-customizations --region us-east-1 \
  --cli-input-json '{"accountColor":"none","visibleServices":[],"visibleRegions":[]}'
```

Empty lists, not null: the CLI rejects null, and leaving the lists out leaves
them as they are.

## How visibility is derived

At plan time, for each account, `modules/account-console` reads:

- the account's path through the organization (root, each OU, the account)
- every SCP attached anywhere on that path
- the services with trusted access to the organization
- the Regions enabled for the account
- the service ids UXC accepts

and hands the policy documents to `modules/scp-visibility`, which decides:

| Visible when | For example |
|---|---|
| A service is allowed at every level of the path, by any action at all | A deny-all-except list naming only `sagemaker:ListHubContents` still shows SageMaker |
| A Region is allowed by every unconditional Region deny, and enabled for the account | A deny on `aws:RequestedRegion` outside `us-east-1` and `us-west-2` shows those two |
| A service has trusted access, and the account is the management account | `sso` when IAM Identity Center is enabled for the organization |

The question is "can anyone in this account reach it?", never "can every
role?". SCPs are the account's ceiling; IAM decides who gets near it. So:

- **Conditions hide nothing.** A deny with a condition still lets something
  through (an approved instance type, a break-glass role), so a guardrail such
  as "only small EC2 instances" leaves EC2 visible.
- **Resource-scoped denies hide nothing**, for the same reason.
- **IAM and permission-set policies are ignored.** Someone who opens a service
  their role cannot use gets a permission error that tells them to switch
  roles, which is the right outcome.
- **A Region deny counts only if `aws:RequestedRegion` is its sole condition
  key.** One that exempts an admin role leaves every Region visible.

The SCP shapes understood are deny-all-except lists (`Deny` with `NotAction`),
allow lists (a level without `FullAWSAccess`, allowing only what its own
`Allow` statements name), whole-service denies (`Deny` of `prefix:*`), and
Region denies using `StringNotEquals`, `StringNotEqualsIgnoreCase` or
`StringNotLike`. Anything else is treated as hiding nothing, so an
unrecognized policy errs towards a fuller console, never an emptier one.

IAM prefixes and console ids mostly match. Where they do not (`logs` lives in
CloudWatch, `ec2` also drives the VPC console, `uxc` is Unified Settings),
`modules/scp-visibility/service_map.tf` maps them. Each account's
`unmapped_prefixes` output lists allowed prefixes that land on no console, such
as `sts` and the billing and cost prefixes, which have no service menu entry to
show or hide. A new entry there is the signal that `service_map.tf` needs a
line.

### The management account

SCPs never bind the management account. For it they are used as a statement of
what the organization has chosen to use, not as a limit, and the services with
trusted access are added because that is where they are administered. Anything
else it needs, such as Support or Health, goes in `extra_visible_services`.

### When the organization changes

Nothing happens until the next plan. A new SCP, an account moved between OUs,
or a newly enabled Region shows up as a diff on `make plan`, and reaches the
console only when that plan is applied.

### What visibility cannot do

A hidden service still appears in console search, marked "Access to this
service is restricted from the Console". UXC has no setting to remove it from
search entirely.

## SCPs and macaw

macaw reads SCPs through the management account and writes each member
account's settings from inside that account, so member accounts need `uxc`
allowed by their SCPs. If yours restrict services to a list, add `uxc:*` to it.

That allows the whole service, not only macaw's role: anyone in a member
account whose IAM role allows it can change that account's console settings,
and the next `make apply` quietly puts them back. To stop that, add a
statement that denies `uxc:UpdateAccountCustomizations`, `uxc:PutAccountColor`
and `uxc:DeleteAccountColor` to every principal except the role in
`member_role_name`. Leave reads open; the console needs them to render itself.

The bootstrap's StackSet is unaffected by SCPs: CloudFormation deploys through
a service-linked role, which SCPs do not bind. It does need `us-east-1` to be
an allowed Region in member accounts.

## Least-privilege setup

`make` runs this repository's scripts and Terraform with macaw's credentials,
and a Terraform plan alone can run arbitrary code. So whatever those
credentials can do, any code you run through macaw can do: a merged pull
request, a dependency, a mistake. With an administrator profile and
`OrganizationAccountAccessRole`, that is the whole organization.

`bootstrap/` makes the answer "change console settings" instead. Applied once
with an administrator profile, it creates:

| Where | What | Can do |
|---|---|---|
| Management account | Identity Center permission set `MacawConsole`, assigned to the users or groups you name | Read the organization; read and write UXC settings; list Regions; assume `macaw-console` |
| Every member account, via a service-managed StackSet | Role `macaw-console` | Read and write that account's UXC settings; list its Regions |

The member role trusts only sessions of the `MacawConsole` permission set in
the management account: the trust policy matches the role Identity Center
creates for it under `/aws-reserved/sso.amazonaws.com/`, a path IAM lets
nothing else use. The StackSet has auto-deployment on, so an account that
joins a target OU gets the role without anyone re-applying.

Steps, from the repository root:

1. Turn on StackSets trusted access, once per organization. Terraform cannot:
   `aws cloudformation activate-organizations-access --region us-east-1 --profile <admin>`
2. `cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars`, and set
   the admin profile and who gets the permission set.
3. `make bootstrap-init bootstrap-plan`, review, `make bootstrap-apply`. It
   prints the CLI profile to add to `~/.aws/config` and the two lines to change
   in `terraform.tfvars`.
4. `make login && make plan`. Expect "No changes": the identities changed, the
   settings did not.

The session policy in `providers.tf` stays, as a guard against bugs when
`member_role_name` points at a broader role. It is not a guard against
malicious code, which could simply drop it; the roles are.

## Credentials

Everything starts from the management-account profile, which should be the
`MacawConsole` permission set. The management account is customized with it
directly, and each member account is reached by assuming `member_role_name`
from it. So one `make login` covers every account, and one `make apply`
updates all of them. Organization data is only ever read through the
management account.

Without the bootstrap, set `member_role_name = "OrganizationAccountAccessRole"`
and use an administrator profile. It works, and `make teardown` and the session
policy behave the same, but read [Least-privilege setup](#least-privilege-setup)
for what it costs.

## How the configuration is generated

UXC settings are per account, with no organization-wide API, so each account
needs its own provider, and Terraform cannot create providers in a loop. So
`scripts/generate.sh` writes one provider, module call and output per account
into `accounts.gen.tf`, from `var.accounts`. The file is gitignored, since it
names your accounts, and `make` regenerates it before `init`, `plan`, `show`,
`hidden`, `destroy` and `lint`. Run `make generate` before calling `terraform`
directly.

## Adding, removing and renaming accounts

- **Add:** add an entry to `accounts`, then `make plan` and `make apply`. If the
  account already has settings made by hand, the first apply overwrites them.
  To adopt them unchanged instead:
  `terraform import 'module.<alias>.aws_uxc_account_customizations.this' <account-id>`.
- **Remove:** delete its entry and apply. UXC has no delete operation, so the
  account is reset to the defaults.
- **Rename:** the alias is the module's address, so renaming it plans a reset
  of the old and a fresh apply of the new. To carry the state across instead,
  run `terraform state mv module.<old> module.<new>` before planning.

## Keeping your settings in version control

`terraform.tfvars` is gitignored, so your organization's details stay out of
this repository. To track them, keep the file in a private repository of your
own and point macaw at it:

```sh
make plan VARS=../my-org-config/org.tfvars
```

Every target accepts `VARS`. One organization per checkout: the state belongs
to whichever organization was applied from it.

## State

Local, and gitignored. Every resource is importable by account ID, so a lost
state file costs one import per account. Move to an S3 backend when macaw is
applied from more than one machine, or from CI.

## Security

macaw changes console settings, nothing else, provided it runs as the
identities from [Least-privilege setup](#least-privilege-setup). Two habits
cover what that cannot:

- **Read before you run.** After pulling, `git log -p ORIG_HEAD..` before any
  `make` target. Never run a contributor's branch with your credentials.
- **No CI with AWS credentials.** Nothing here needs it, and a workflow that
  plans pull requests with credentials hands them to whoever opens one.

`scripts/github-settings.sh` (`make github-settings REPO=owner/repo`) applies
the GitHub side: changes to the default branch only by pull request, no force
pushes or deletion, Actions off, and secret scanning and private vulnerability
reporting once the repository is public. Run it after the first push, and again
after making the repository public.

Report a vulnerability privately through the repository's Security tab.

## Development

```sh
make lint    # fmt check, validate (both configurations), tests, script syntax, dash check
make test    # offline: the SCP rules, and the teardown parser against Terraform's
```

`modules/scp-visibility` is pure, with no providers or API calls, so every rule
is tested by `terraform test` against made-up SCPs in its `tests/` directory.

## License

BSD 3-Clause. See [LICENSE.txt](LICENSE.txt).
