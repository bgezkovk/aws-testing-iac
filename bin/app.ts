#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { AppContext, REGION, STACK_NAMES, TAGS } from '../lib/config';
import { FoundationStack } from '../lib/foundation-stack';
import { ClusterStack } from '../lib/cluster-stack';

const app = new cdk.App();

const ctx = (key: keyof AppContext) => {
  const v = app.node.tryGetContext(key);
  if (v === undefined) throw new Error(`Missing CDK context value: ${key}`);
  return v;
};

const appCtx: AppContext = {
  githubRepo: ctx('githubRepo'),
  githubOwnerId: String(ctx('githubOwnerId')),
  githubRepoId: String(ctx('githubRepoId')),
  githubDeployBranch: ctx('githubDeployBranch'),
  // Not in cdk.json (public repo): from ~/.cdk.json context, -c budgetEmail=..., or BUDGET_EMAIL.
  budgetEmail: app.node.tryGetContext('budgetEmail') ?? process.env.BUDGET_EMAIL ?? '',
  budgetLimitUsd: Number(ctx('budgetLimitUsd')),
  clusterName: ctx('clusterName'),
  kubernetesVersion: ctx('kubernetesVersion'),
  nodeInstanceTypes: ctx('nodeInstanceTypes'),
};

const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region: REGION };

// Deployed once, manually, with your own admin credentials. Never nuked.
if (appCtx.budgetEmail) {
  new FoundationStack(app, 'Foundation', { stackName: STACK_NAMES.foundation, env, appCtx });
} else {
  // CI never deploys Foundation, so it doesn't need the address. Locally `cdk deploy Foundation`
  // then fails with "No stacks match", which is the cue to set the address.
  console.error('Foundation stack skipped: set budgetEmail in ~/.cdk.json context, -c budgetEmail=..., or BUDGET_EMAIL.');
}

// Spun up / down by the pipeline. Independent of Foundation (references IAM by fixed name, no exports).
new ClusterStack(app, 'Cluster', { stackName: STACK_NAMES.cluster, env, appCtx });

for (const [k, v] of Object.entries(TAGS)) cdk.Tags.of(app).add(k, v);
