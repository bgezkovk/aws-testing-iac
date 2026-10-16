# cleanup

`cleanup.sh` brings the aws-testing account back to ~$0/month. It destroys the `aws-testing-cluster` stack with `cdk destroy` (falling back to a CloudFormation delete), then runs [aws-nuke](https://github.com/ekristen/aws-nuke) v3 (pinned version, checksum-verified download) in every enabled region, and finally lists any billable leftovers (EIPs, EBS, snapshots, NAT, ELBs, EC2, EKS, RDS, log groups with data). It exits non-zero if anything is left.

**Protected** (`aws-nuke.yaml`, preset `foundation`). Name filters apply in every region:
- Stacks `aws-testing-foundation` and `CDKToolkit` (eu-west-1).
- The `devops` user with its policies, keys, MFA and login profile. Roles `devops-admin`, `devops-read-only` and `github-actions-deployer`, the GitHub Actions OIDC provider (`token.actions.githubusercontent.com`), and the budget `aws-testing-monthly`.
- CDK bootstrap resources: the `cdk-hnb659fds-*` roles, the assets bucket (the bucket is kept and its objects are deleted), the container-assets ECR repo and the SSM parameter `/cdk-bootstrap/hnb659fds/version`.
- Default VPCs, the password policy, virtual MFA devices and the account alias.

**Run locally** with `devops-admin` credentials:
```sh
export EXPECTED_ACCOUNT_ID=123456789012            # must match the current credentials, or the script stops
./cleanup/cleanup.sh plan                          # dry run (the default), deletes nothing
CONFIRM_NUKE=yes ./cleanup/cleanup.sh run          # really deletes
./cleanup/cleanup.sh report                        # only the leftover check
```
If the account has no alias, the script creates `aws-testing-<account id>`, because aws-nuke requires one. In `run` mode the script stops if the GitHub OIDC provider does not exist (Foundation stack not deployed).
