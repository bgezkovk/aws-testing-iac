/**
 * Shared contract between stacks, cleanup config and CI.
 * Names here are FIXED: aws-nuke filters, .github/workflows and scripts rely on them.
 * Change them in one place only, and update cleanup/aws-nuke.yaml + .github/workflows to match.
 */
// eu-west-1, not eu-north-1: AWS::Budgets::Budget is not in eu-north-1's CloudFormation
// resource spec, and keeping everything in one region means one stack set + one bootstrap.
export const REGION = 'eu-west-1';

export const TAGS = {
  project: 'aws-testing',
  'managed-by': 'cdk',
} as const;

export const STACK_NAMES = {
  foundation: 'aws-testing-foundation',
  cluster: 'aws-testing-cluster',
} as const;

export const IAM_NAMES = {
  devopsUser: 'devops',
  adminRole: 'devops-admin',
  readOnlyRole: 'devops-read-only',
  ciRole: 'github-actions-deployer',
  budget: 'aws-testing-monthly',
} as const;

/** ECR repo for the patched network-policy-agent image (lives in the cluster stack). */
export const ECR_REPO_NAME = 'network-policy-agent';

export interface AppContext {
  githubRepo: string;         // owner/repo, e.g. bgezkovk/aws-testing-iac
  // Numeric IDs (gh api repos/<owner>/<repo> --jq '.owner.id, .id'). GitHub puts them in the OIDC
  // sub claim: repo:<owner>@<ownerId>/<repo>@<repoId>:ref:... Pinning them means a deleted/renamed
  // repo re-created under the same name by someone else does not match.
  githubOwnerId: string;
  githubRepoId: string;
  githubDeployBranch: string; // branch allowed to assume the CI role
  budgetEmail: string;
  budgetLimitUsd: number;
  clusterName: string;
  kubernetesVersion: string;
  nodeInstanceTypes: string[];
}
