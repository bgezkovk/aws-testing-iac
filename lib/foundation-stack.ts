import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import { Construct } from 'constructs';
import { AppContext, IAM_NAMES } from './config';

export type FoundationStackProps = cdk.StackProps & { appCtx: AppContext };

/**
 * Long-lived account foundation: human access (devops user + MFA-gated roles),
 * GitHub Actions OIDC access, and a cost budget. Deployed once manually, never nuked.
 */
export class FoundationStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: FoundationStackProps) {
    super(scope, id, props);
    const { appCtx } = props;

    // ---- Human access -------------------------------------------------------
    // No access keys / console password here: the user creates them self-service
    // (or an admin sets a login profile once) so no secrets ever land in CFN.
    const user = new iam.User(this, 'DevopsUser', { userName: IAM_NAMES.devopsUser });

    const mfaTrust = (u: iam.IUser) =>
      new iam.ArnPrincipal(u.userArn).withConditions({
        Bool: { 'aws:MultiFactorAuthPresent': 'true' },
      });

    const adminRole = new iam.Role(this, 'DevopsAdminRole', {
      roleName: IAM_NAMES.adminRole,
      assumedBy: mfaTrust(user),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AdministratorAccess')],
      maxSessionDuration: cdk.Duration.hours(1),
    });

    const readOnlyRole = new iam.Role(this, 'DevopsReadOnlyRole', {
      roleName: IAM_NAMES.readOnlyRole,
      assumedBy: mfaTrust(user),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('ReadOnlyAccess')],
      maxSessionDuration: cdk.Duration.hours(4),
    });

    const userSelf = `arn:${this.partition}:iam::${this.account}:user/\${aws:username}`;
    const userMfa = `arn:${this.partition}:iam::${this.account}:mfa/\${aws:username}`;

    user.attachInlinePolicy(
      new iam.Policy(this, 'DevopsUserPolicy', {
        policyName: 'devops-self-service',
        statements: [
          new iam.PolicyStatement({
            sid: 'AssumeDevopsRoles',
            actions: ['sts:AssumeRole'],
            resources: [adminRole.roleArn, readOnlyRole.roleArn],
          }),
          new iam.PolicyStatement({
            sid: 'ManageOwnMfa',
            actions: [
              'iam:CreateVirtualMFADevice',
              'iam:DeleteVirtualMFADevice',
              'iam:EnableMFADevice',
              'iam:DeactivateMFADevice',
              'iam:ListMFADevices',
              'iam:ResyncMFADevice',
            ],
            resources: [userSelf, userMfa],
          }),
          new iam.PolicyStatement({
            sid: 'ManageOwnCredentials',
            actions: [
              'iam:ChangePassword',
              'iam:GetUser',
              'iam:GetLoginProfile',
              'iam:CreateAccessKey',
              'iam:ListAccessKeys',
              'iam:DeleteAccessKey',
              'iam:UpdateAccessKey',
            ],
            resources: [userSelf],
          }),
          new iam.PolicyStatement({
            sid: 'AccountLevelReads',
            actions: ['iam:GetAccountPasswordPolicy', 'iam:ListVirtualMFADevices'],
            resources: ['*'],
          }),
        ],
      }),
    );

    // ---- GitHub Actions (OIDC) ----------------------------------------------
    // L1 provider: avoids the custom-resource Lambda of the L2 OpenIdConnectProvider.
    // ThumbprintList is optional; IAM validates GitHub's IdP via its trusted CA store.
    // Workflows get the token via aws-actions/configure-aws-credentials
    // (permissions: id-token: write), audience sts.amazonaws.com.
    const githubHost = 'token.actions.githubusercontent.com';
    const oidc = new iam.CfnOIDCProvider(this, 'GithubOidcProvider', {
      url: `https://${githubHost}`,
      clientIdList: ['sts.amazonaws.com'],
    });

    // sub is exact: only workflow runs on the deploy branch of this repo. GitHub's sub uses
    // immutable ids: repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/<branch>.
    // Jobs must NOT use a GitHub `environment:` - that changes the suffix to :environment:<name>.
    const [owner, repo] = appCtx.githubRepo.split('/');
    const sub = `repo:${owner}@${appCtx.githubOwnerId}/${repo}@${appCtx.githubRepoId}:ref:refs/heads/${appCtx.githubDeployBranch}`;
    const ciRole = new iam.Role(this, 'GithubActionsRole', {
      roleName: IAM_NAMES.ciRole,
      assumedBy: new iam.WebIdentityPrincipal(oidc.attrArn, {
        StringEquals: {
          [`${githubHost}:aud`]: 'sts.amazonaws.com',
          [`${githubHost}:sub`]: sub,
        },
      }),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AdministratorAccess')],
      maxSessionDuration: cdk.Duration.hours(2),
    });

    // ---- Cost guardrail -----------------------------------------------------
    // First two budgets per account are free.
    const notify = (notificationType: 'ACTUAL' | 'FORECASTED', threshold: number) => ({
      notification: {
        notificationType,
        comparisonOperator: 'GREATER_THAN',
        threshold,
        thresholdType: 'PERCENTAGE',
      },
      subscribers: [{ subscriptionType: 'EMAIL', address: appCtx.budgetEmail }],
    });

    new budgets.CfnBudget(this, 'MonthlyBudget', {
      budget: {
        budgetName: IAM_NAMES.budget,
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        budgetLimit: { amount: appCtx.budgetLimitUsd, unit: 'USD' },
      },
      notificationsWithSubscribers: [
        notify('ACTUAL', 50),
        notify('ACTUAL', 100),
        notify('FORECASTED', 100),
      ],
    });

    // ---- Outputs ----------------------------------------------------------------
    const switchRoleUrl = (roleName: string) =>
      `https://signin.aws.amazon.com/switchrole?roleName=${roleName}&account=${this.account}&displayName=${roleName}`;

    new cdk.CfnOutput(this, 'DevopsUserArn', { value: user.userArn });
    new cdk.CfnOutput(this, 'DevopsAdminRoleArn', { value: adminRole.roleArn });
    new cdk.CfnOutput(this, 'DevopsReadOnlyRoleArn', { value: readOnlyRole.roleArn });
    new cdk.CfnOutput(this, 'GithubActionsRoleArn', {
      value: ciRole.roleArn,
      description: 'Set as GitHub Actions repository variable AWS_ROLE_ARN',
    });
    new cdk.CfnOutput(this, 'DevopsAdminSwitchRoleUrl', { value: switchRoleUrl(IAM_NAMES.adminRole) });
    new cdk.CfnOutput(this, 'DevopsReadOnlySwitchRoleUrl', { value: switchRoleUrl(IAM_NAMES.readOnlyRole) });
  }
}
