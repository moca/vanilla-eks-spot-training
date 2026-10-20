# Third-party notices

## awslabs/ai-on-eks

The following files contain material adapted and modified from
[`awslabs/ai-on-eks`](https://github.com/awslabs/ai-on-eks) at revision
[`a003ada9bff052eca250ce24e5cfc5f532f2aab3`](https://github.com/awslabs/ai-on-eks/tree/a003ada9bff052eca250ce24e5cfc5f532f2aab3):

- `terraform/live/eks/amp.tf`: the Amazon Managed Service for Prometheus IAM
  action set was narrowed from
  [`infra/base/terraform/amp.tf`](https://github.com/awslabs/ai-on-eks/blob/a003ada9bff052eca250ce24e5cfc5f532f2aab3/infra/base/terraform/amp.tf#L92-L108).
- `terraform/live/eks/observability.tf`: the Prometheus remote-write queue
  settings were translated from YAML in
  [`infra/base/terraform/helm-values/kube-prometheus.yaml`](https://github.com/awslabs/ai-on-eks/blob/a003ada9bff052eca250ce24e5cfc5f532f2aab3/infra/base/terraform/helm-values/kube-prometheus.yaml#L18-L25)
  into Terraform-generated Helm values.

That upstream work is licensed under the Apache License 2.0; a copy is in
[`LICENSES/Apache-2.0-ai-on-eks.txt`](LICENSES/Apache-2.0-ai-on-eks.txt).
Its upstream `NOTICE` states:

> Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
