# Works out which Regions and console services an account can use at all,
# from the SCPs on its path through the organization.
#
# Pure: no providers, no API calls. The caller fetches the policies and passes
# the documents in, so every rule below can be exercised by `terraform test`
# with made-up SCPs (see tests/).
#
# The question asked of each Region and service is "is any of it reachable
# from this account?", not "can every role use it?". SCPs set the ceiling for
# the whole account; IAM decides who gets how close to it. So:
#
#   - A statement with a condition does not hide anything. A condition means
#     somebody, somewhere, gets through: a break-glass role, an approved
#     instance type, a tagged resource. Hiding the service would hide it from
#     them too.
#   - A statement scoped to particular resources does not hide anything
#     either, for the same reason.
#   - A service that is allowed for even one action stays visible.
#     `sagemaker:ListHubContents` alone keeps SageMaker on the menu.
#
# The one exception to "conditions do not hide" is the Region rule itself,
# which is a condition on aws:RequestedRegion -- and only when that is the
# statement's sole condition key, so a Region deny that exempts some principal
# leaves the Region visible.

locals {
  # One entry per level of the path (root, each OU, the account), each holding
  # the statements of every SCP attached there, normalized so that the fields
  # IAM allows as either a string or a list are always lists.
  levels = [
    for l in var.policy_levels : {
      target = l.target
      statements = flatten([
        for p in l.policies : [
          for s in flatten([jsondecode(p.content).Statement]) : {
            effect     = s.Effect
            action     = [for a in try(flatten([s.Action]), []) : lower(a)]
            not_action = [for a in try(flatten([s.NotAction]), []) : lower(a)]
            resource   = try(flatten([s.Resource]), [])
            conditions = try(s.Condition, {})
          }
        ]
      ])
    }
  ]

  statements = flatten([for l in local.levels : l.statements])

  # ---- Services ----------------------------------------------------------

  # SCPs are evaluated level by level: an action must be allowed at every
  # level, and a level allows it only if some Allow statement there does.
  # FullAWSAccess allows "*", so a level carrying it contributes no limit.
  # A level without it is using allow-list SCPs, and its Allow statements are
  # the whole list for that level.
  #
  # An Allow with NotAction is treated as a full allow. It is rare in SCPs, and
  # erring towards visible is the cheap mistake.
  level_allowlists = [
    for l in local.levels : toset(flatten([
      for s in l.statements : [for a in s.action : split(":", a)[0]]
      if s.effect == "Allow" && contains(s.resource, "*")
    ]))
    if !anytrue([
      for s in l.statements :
      s.effect == "Allow" && contains(s.resource, "*") && (contains(s.action, "*") || length(s.not_action) > 0)
    ])
  ]

  # The deny-list form of the same thing: "Deny everything except these",
  # unconditionally: the usual way to restrict an organization to a list of
  # services without detaching FullAWSAccess.
  deny_allowlists = [
    for s in local.statements : toset([for a in s.not_action : split(":", a)[0]])
    if s.effect == "Deny" && length(s.not_action) > 0 && !contains(s.not_action, "*")
    && length(s.conditions) == 0 && contains(s.resource, "*")
  ]

  allowlists = concat(local.level_allowlists, local.deny_allowlists)

  # Whole services denied outright, e.g. `Deny ds:*` with no condition. A
  # deny of individual actions leaves the rest of the service reachable, so
  # only the `prefix:*` form counts.
  denied_prefixes = toset(flatten([
    for s in local.statements : [for a in s.action : split(":", a)[0] if endswith(a, ":*")]
    if s.effect == "Deny" && length(s.conditions) == 0 && contains(s.resource, "*")
  ]))

  services_restricted = length(local.allowlists) > 0 || length(local.denied_prefixes) > 0

  # With an allow-list, candidates are what some list names; without one,
  # every prefix this module knows about. Either way a prefix survives only if
  # every list admits it and nothing denies it outright.
  known_prefixes = setunion(keys(local.service_map), var.console_services)
  candidate_prefixes = (
    length(local.allowlists) > 0 ? setunion(local.allowlists...) : local.known_prefixes
  )
  allowed_prefixes = toset([
    for p in local.candidate_prefixes : p
    if alltrue([for al in local.allowlists : contains(al, p)]) && !contains(local.denied_prefixes, p)
  ])

  # "sso.amazonaws.com" -> "sso". For nested principals such as
  # member.org.stacksets.cloudformation.amazonaws.com, the label directly
  # before amazonaws.com is the owning service.
  trusted_prefixes = toset([
    for sp in var.trusted_service_principals : regex("([a-z0-9-]+)\\.amazonaws\\.com$", lower(sp))[0]
  ])

  reachable_prefixes = setunion(
    local.allowed_prefixes,
    var.include_trusted_services ? local.trusted_prefixes : [],
  )

  mapped_services = toset(flatten([
    for p in local.reachable_prefixes : lookup(local.service_map, p, [p])
  ]))

  visible_services = (
    local.services_restricted
    ? sort(setintersection(setunion(local.mapped_services, var.extra_visible_services), var.console_services))
    : null
  )

  # Reachable prefixes that did not land on any console id. Not an error --
  # sts and pricing have no console of their own -- but a new entry here is
  # the signal that service_map needs a line.
  unmapped_prefixes = sort([
    for p in local.reachable_prefixes : p
    if length(setintersection(lookup(local.service_map, p, [p]), var.console_services)) == 0
  ])

  # ---- Regions -----------------------------------------------------------

  region_operators = ["StringNotEquals", "StringNotEqualsIgnoreCase", "StringNotLike"]

  # Each rule is the list of Region patterns one statement allows. A statement
  # qualifies when it denies every service (Action "*", or the NotAction form
  # that exempts global services), applies to every resource, and conditions on
  # nothing but aws:RequestedRegion.
  region_rules = [
    for s in local.statements : flatten([
      for op in local.region_operators : try(flatten([s.conditions[op]["aws:RequestedRegion"]]), [])
    ])
    if s.effect == "Deny"
    && (contains(s.action, "*") || length(s.not_action) > 0)
    && contains(s.resource, "*")
    && length(s.conditions) == 1
    && alltrue([for op, kv in s.conditions : contains(local.region_operators, op) && length(kv) == 1 && contains(keys(kv), "aws:RequestedRegion")])
  ]

  # Patterns are matched as StringNotLike globs even under StringNotEquals,
  # which is harmless: a literal Region name contains no wildcard.
  visible_regions = (
    length(local.region_rules) > 0
    ? sort([
      for r in var.enabled_regions : r
      if alltrue([
        for rule in local.region_rules : anytrue([
          for g in rule : can(regex("^${replace(replace(replace(g, ".", "\\."), "*", ".*"), "?", ".")}$", r))
        ])
      ])
    ])
    : null
  )
}
