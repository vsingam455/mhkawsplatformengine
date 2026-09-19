# infra

AWS foundations that the platform's pipelines and agents depend on. CloudFormation, deployed with
the AWS CLI by a platform admin (not by a pipeline: these stacks define what pipelines may do).

## github-oidc.yml

Lets GitHub Actions in the MHK organization reach AWS account resources without stored keys.

| Role | Who can assume it | What it can do |
| ---- | ----------------- | -------------- |
| `gha-agent-bedrock`   | any workflow in the org | Invoke Anthropic models on Bedrock. Nothing else. |
| `gha-devops-readonly` | any workflow in the org | Read CloudFormation events and CloudWatch logs. |
| `gha-deploy-dev` / `-qa` / `-prod` | only jobs running in the GitHub Environment of the same name | Deploy CloudFormation/SAM stacks named `mhk-<env>-*` |

Because the deploy roles are tied to GitHub Environments, the required reviewers configured on the
`qa` and `prod` environments are what gate promotion.

Deploy (once per AWS account):

```
aws cloudformation deploy \
  --stack-name mhk-github-oidc \
  --template-file infra/github-oidc.yml \
  --parameter-overrides GitHubOrg=<org> \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation describe-stacks --stack-name mhk-github-oidc --query "Stacks[0].Outputs"
```

Then set the org variable `AWS_BEDROCK_ROLE_ARN` to the `AgentBedrockRoleArn` output.

### Known limits
- One AWS account holds dev, qa and prod, separated by stack name. Separate accounts per
  environment is the stronger design and should follow once the pipeline is proven.
- `mhk-cfn-exec` (the role CloudFormation uses inside app stacks) can create IAM roles named
  `mhk-*` without a permissions boundary, so a merged template could grant itself broad access.
  Human review of every PR is the control today; add a permissions boundary before production use.
