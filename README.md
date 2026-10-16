# aws-testing-iac

IaC for a personal AWS **testing** account (`eu-west-1`), used to test fixes to the
[aws-network-policy-agent](https://github.com/aws/aws-network-policy-agent) on a throwaway
single-node EKS cluster. Goal: **≈ $0 when idle, < $10/month total.**

| Stack | Region | Lifecycle | Contents |
|---|---|---|---|
| `aws-testing-foundation` (`Foundation`) | eu-west-1 | once, manual | `devops` user, `devops-admin` / `devops-read-only` roles (MFA), GitHub Actions OIDC + `github-actions-deployer` role, $10/month budget (e-mail at 50% / 100% / 100% forecast) |
| `aws-testing-cluster` (`Cluster`) | eu-west-1 | up/down via CI | public-subnet VPC (no NAT), EKS + 1 spot `t3a.medium` node, ECR repo; **self-managed** VPC CNI (Helm) with network policy |

Why eu-west-1: `AWS::Budgets::Budget` is not in eu-north-1's CloudFormation resource spec, so
eu-north-1 would need a second stack + bootstrap in another region. eu-west-1 keeps everything
in one region; EKS pricing is identical and spot node price differences are fractions of a cent/hour.

Cluster cost while running ≈ **$0.12/h** (EKS control plane $0.10 + spot node + public IPv4 + 20 GB gp3).
$10 buys ~80 cluster-hours/month. Destroyed, the account costs cents (CDK bootstrap bucket).

## Layout

```
bin/app.ts               CDK app (2 stacks)
lib/config.ts            shared contract: fixed names, region, tags — referenced by cleanup + CI
lib/foundation-stack.ts  IAM + GitHub Actions OIDC + budget
lib/cluster-stack.ts     VPC + EKS (L1 only: no Lambdas / custom resources) + ECR
k8s/aws-vpc-cni-values.yaml  Helm values for the self-managed VPC CNI (network policy on)
scripts/assume-role.sh   devops user -> admin / read_only with MFA
scripts/kubeconfig.sh    update kubeconfig for the test cluster
scripts/install-cni.sh   adopt EKS-bootstrapped aws-node into Helm + install with network policy
scripts/set-npa-image.sh build/push patched node agent and roll it out (helm upgrade)
cleanup/                 aws-nuke config + cleanup.sh (see cleanup/README.md)
scripts/cluster-down.sh  delete the cluster stack (optionally only if older than N hours)
.github/workflows/       validate (PR/push), cluster (up/down + 2-hourly reaper), nuke (plan/run)
.github/actions/aws-login  GitHub OIDC -> AWS credentials + account check
```

## AWS console steps

Everything else is code; these are the clicks it can't do. Use region **Europe (Ireland) eu-west-1**
(top-right region selector) whenever a step is regional.

### A. Before the first deploy (as root / current account owner)

1. **Secure the root user.** Account menu (top right) → *Security credentials* →
   *Multi-factor authentication (MFA)* → *Assign MFA device*. Delete any root access keys listed there.
2. **Let IAM roles see billing.** Account menu → *Account* → *IAM user and role access to
   Billing information* → *Edit* → tick *Activate IAM Access* → *Update*.
   Without this, `devops-admin` can't open Billing / Budgets / Cost Explorer in the console.
3. **Set an account alias** (optional, nicer sign-in URL). *IAM* → *Dashboard* →
   *AWS Account* → *Account alias* → *Create*, e.g. `aws-testing-<account-id>`.
   Must **not** contain `prod` — aws-nuke refuses to run on such accounts.
   If you skip this, `cleanup.sh` creates `aws-testing-<account-id>` for you.
4. **Create a temporary bootstrap admin** (so you never use root keys).
   *IAM* → *Users* → *Create user* → name `bootstrap-admin`, no console access →
   *Attach policies directly* → `AdministratorAccess` → *Create user*.
   Open the user → *Security credentials* → *Create access key* → *Command Line Interface (CLI)*.
   Put the keys in `~/.aws/credentials` under any profile name (e.g. `aws configure --profile lab`).
5. **Check the spot quota** (new accounts are sometimes at 0).
   *Service Quotas* → *AWS services* → *Amazon Elastic Compute Cloud (Amazon EC2)* →
   search `All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests`.
   It must be **≥ 2** (vCPUs of one `t3a.medium`). If lower → *Request increase at account level* → `4`.
6. *(Optional)* **Free-tier alerts.** *Billing and Cost Management* → *Billing preferences* →
   *Alert preferences* → *Edit* → tick *Receive AWS Free Tier alerts*.

### B. After `cdk deploy Foundation` (as `bootstrap-admin` or root)

7. **Give `devops` its credentials.** *IAM* → *Users* → `devops` → *Security credentials*:
   - *Console access* → *Enable* → custom password, untick "must create new password" (or keep it, the
     user is allowed to change its own password).
   - *Access keys* → *Create access key* → *CLI* → store as profile `devops` in `~/.aws/credentials`
     (used by `scripts/assume-role.sh`).
8. **Register MFA for `devops`.** Sign out, then sign in as `devops` at
   `https://<account-alias or id>.signin.aws.amazon.com/console`.
   Account menu → *Security credentials* → *Assign MFA device* → *Authenticator app*,
   **device name `devops`** (the policy only allows an MFA device named after the user).
   Without MFA, both roles refuse the assume.
9. **Switch into the roles in the console.** Open the `DevopsAdminSwitchRoleUrl` /
   `DevopsReadOnlySwitchRoleUrl` outputs of the Foundation stack (*CloudFormation* →
   `aws-testing-foundation` → *Outputs*) while signed in as `devops` → *Switch Role*.
   They then stay in the account menu's role history.
10. **Verify the GitHub trust.** *IAM* → *Identity providers* → `token.actions.githubusercontent.com`
    should be listed with audience `sts.amazonaws.com`. Copy `GithubActionsRoleArn` from the stack
    outputs for GitHub.
11. **Verify the budget.** *Billing and Cost Management* → *Budgets* → `aws-testing-monthly`
    ($10, 3 alerts). E-mail subscribers need no confirmation.

### C. Retire the bootstrap admin (once `devops-admin` works)

12. Confirm `eval "$(scripts/assume-role.sh admin <mfa>)" && aws sts get-caller-identity` shows
    `assumed-role/devops-admin`.
13. *IAM* → *Users* → `bootstrap-admin` → *Delete* (deletes its access key too).
    aws-nuke would delete it anyway, as it is not in the protected list.

### D. Checking that you're really at ~$0

- *Billing and Cost Management* → *Bills* (current month, by service) and *Cost Explorer*
  (group by *Service*, daily) — EKS/EC2/VPC lines should stop growing after `cluster:down`.
- Typical leftovers if something went wrong: *EC2* → *Elastic IPs*, *Volumes*, *Snapshots*;
  *VPC* → *NAT gateways*; *EKS* → *Clusters*. `cleanup/cleanup.sh report` checks all of these
  across regions.

## One-time setup (from your laptop)

Do [console steps A](#a-before-the-first-deploy-as-root--current-account-owner) first.

1. Edit `cdk.json` context:
   - `githubRepo` — `owner/repo` of this repository on GitHub (case-sensitive, must match exactly;
     only workflows on `githubDeployBranch` of that repo can assume the CI role)

   Set the budget e-mail **outside the repo** (it is public) — once, in your user-level CDK config
   `~/.cdk.json`, which CDK merges into every app's context:
   ```json
   { "context": { "budgetEmail": "you@example.com" } }
   ```
   (or per command: `-c budgetEmail=...` / `BUDGET_EMAIL=...`). Without it the Foundation stack is
   skipped and `cdk deploy Foundation` fails with "No stacks match" — CI never needs it.
2. Install, bootstrap and deploy the foundation:
   ```sh
   npm ci
   export AWS_PROFILE=<profile from console step A4>   # check: aws sts get-caller-identity
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   npx cdk bootstrap aws://$ACCOUNT/eu-west-1
   npx cdk deploy Foundation
   ```
3. Do [console steps B](#b-after-cdk-deploy-foundation-as-bootstrap-admin-or-root)
   (`devops` password/keys + MFA, verify OIDC provider and budget).
4. GitHub → repo → *Settings* → *Secrets and variables* → *Actions* → **Secrets** tab →
   *New repository secret* (secrets, not variables, so GitHub masks them in the public logs):
   - `AWS_ROLE_ARN` = `GithubActionsRoleArn` output of the Foundation stack
   - `AWS_ACCOUNT_ID` = the account id
5. Lock down the repo — see [Public repository](#public-repository) for why:
   - *Settings* → *Rules* → *Rulesets* (or *Branches*): protect `main` — require a pull request,
     block force pushes and deletion.
   - *Settings* → *Actions* → *General*:
     - *Fork pull request workflows from outside collaborators* → **Require approval for all external contributors**
     - *Workflow permissions* → **Read repository contents and packages permissions**
   - *Settings* → *Code security*: enable **Dependabot security updates** (version updates are
     configured in `.github/dependabot.yml`).
6. Do [console steps C](#c-retire-the-bootstrap-admin-once-devops-admin-works): delete
   `bootstrap-admin` and use `devops-admin` from here on.

## Daily use

```sh
# local credentials (devops user profile + MFA)
eval "$(scripts/assume-role.sh admin 123456)"

# GitHub: Actions -> cluster -> Run workflow (main, action=up), ~15 min.
#   (or: gh workflow run cluster.yml -f action=up)
# It also runs scripts/install-cni.sh (self-managed CNI, network policy on).
# Re-running "up" resets the node agent to the chart's default image.
# A 2-hourly scheduled run deletes the cluster once it is >8h past its last create/update.
scripts/kubeconfig.sh --admin
kubectl -n kube-system get ds aws-node -o wide

# test your fix
scripts/set-npa-image.sh --build ~/src/aws-network-policy-agent   # build, push to ECR, helm upgrade
scripts/set-npa-image.sh --reset                                  # back to the chart's default image

# when finished: gh workflow run cluster.yml -f action=down   (or scripts/cluster-down.sh)
```

## Public repository

This repo is designed to be public. Nothing in it is secret, and the AWS side only trusts
workflow runs on `main` of this exact repo. What that relies on, and what to keep in mind:

| Topic | How it's handled |
|---|---|
| Credentials | None in the repo. CI uses GitHub OIDC → short-lived STS credentials. `AWS_ROLE_ARN` / `AWS_ACCOUNT_ID` are repository **secrets**, so they are masked in logs. |
| Forks / PRs | The CI role trusts only `repo:<githubRepo>:ref:refs/heads/main`. PR runs (fork or not) get a different OIDC subject, and fork PRs get no secrets. `validate` has no AWS access. `pull_request_target` is not used — keep it that way. |
| Who can deploy / nuke | Only users with write access can trigger `workflow_dispatch` or merge to `main`. Protecting `main` is what keeps admin rights in the account behind review. |
| Public logs | Logs of public repos are world-readable. The account id is masked (secret + `mask-aws-account-id`). Workflows don't print stack outputs, and the nuke plan is not uploaded as an artifact or summary — for the full inventory run `cleanup/cleanup.sh plan` locally. |
| Personal data | The budget e-mail lives in `~/.cdk.json`, not in this repo. |
| Supply chain | All third-party actions are pinned to commit SHAs (the CI role is admin). Dependabot opens weekly PRs to bump them; review those before merging. |
| Don't add | `environment:` on AWS jobs (changes the OIDC subject → assume fails), `pull_request_target`, or AWS steps in `validate`. Never commit `kubeconfig*`, `.env` or `cdk.context.json` with real values (already in `.gitignore`). |
| Scheduled reaper | GitHub **disables scheduled workflows in public repos after 60 days without commits**. If that happens, the cluster won't auto-stop — re-enable it under *Actions* → *cluster*. The $10 budget alert is the backstop. |
| Cost | Actions minutes are free for public repos, so the 2-hourly reaper costs nothing. |

## Cleaning the account

GitHub: Actions → *nuke* → Run workflow with `mode=plan`, read the job log
(or run `cleanup/cleanup.sh plan` locally for the unmasked view), then run again with `mode=run` and `confirm` = `nuke <account id>`
(`gh workflow run nuke.yml -f mode=run -f confirm="nuke 123456789012"`).
It destroys the cluster stack, runs aws-nuke over all regions while protecting the Foundation
stack, `devops*`/CI IAM, the GitHub OIDC provider and CDK bootstrap, and fails if anything
billable is left.
Locally: see `cleanup/README.md`.
