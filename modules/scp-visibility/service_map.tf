locals {
  # IAM action prefix -> UXC console service ids.
  #
  # Most prefixes need no entry: `s3`, `lambda`, `bedrock` and the rest are
  # spelt the same in both, and anything not listed here is looked up as
  # itself. Entries exist for the three ways the two namespaces disagree.
  #
  # `make services` prints the full list of UXC ids, and the unmapped_prefixes
  # output lists every reachable prefix that currently lands on nothing.
  service_map = {
    # Prefixes whose console lives under another service.
    aoss           = ["es"]         # OpenSearch Serverless, inside the OpenSearch console
    identitystore  = ["sso"]        # IAM Identity Center's user store
    logs           = ["cloudwatch"] # CloudWatch Logs
    route53domains = ["route53"]    # Registered domains
    s3vectors      = ["s3"]         # Vector buckets, inside the S3 console
    sso-directory  = ["sso"]
    uxc            = ["settings"] # Unified Settings, where visible Regions and services are chosen
    waf            = ["wafv2"]    # WAF Classic, now inside the WAF console
    waf-regional   = ["wafv2"]

    # Prefixes that feed more than one console. The VPC console is driven
    # entirely by ec2:* actions.
    ec2    = ["ec2", "vpc"]
    health = ["health-dashboard"]

    # Console ids with no IAM prefix of that name. Mapping them to nothing
    # means only the entries above can make them visible; otherwise a deny of
    # ec2:* would hide EC2 and leave VPC on the menu.
    vpc              = []
    health-dashboard = []
  }
}
