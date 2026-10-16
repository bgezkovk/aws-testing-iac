/**
 * Ephemeral EKS cluster for testing the aws-network-policy-agent fix
 * (aws-eks-nodeagent container in the aws-node DaemonSet of the VPC CNI).
 *
 * The VPC CNI is SELF-MANAGED: EKS bootstraps a plain aws-node DaemonSet at cluster creation
 * (enough for the node to go Ready), then scripts/install-cni.sh adopts it into a Helm release
 * with network policy enabled. Full control of the DaemonSet, nothing on the EKS side reverts it.
 *
 * Spun up for a test session, destroyed afterwards. Cheapest possible:
 * public subnets only (no NAT, no VPC endpoints), 1 spot node, no control-plane logs,
 * L1 EKS constructs only -> no kubectl Lambdas, no custom resources, no nested stacks.
 *
 * Estimated hourly cost while up (eu-west-1):
 *   EKS control plane (standard support) ..... $0.10/h
 *   1x spot t3a.medium / t3.medium ........... ~$0.010-0.015/h
 *   1x public IPv4 on the node ............... $0.005/h
 *   20 GB gp3 root volume (prorated) ......... ~$0.002/h
 *   ECR storage (a few images) ............... pennies/month
 *   ------------------------------------------------------
 *   Total .................................... ~$0.12/h
 */
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { AppContext, ECR_REPO_NAME, IAM_NAMES, REGION } from './config';

export class ClusterStack extends cdk.Stack {
  // Fixed AZs instead of a synth-time context lookup, so `cdk synth` needs no credentials (CI validate).
  override get availabilityZones(): string[] {
    return [`${REGION}a`, `${REGION}b`];
  }

  constructor(scope: Construct, id: string, props: cdk.StackProps & { appCtx: AppContext }) {
    super(scope, id, props);
    const { appCtx } = props;

    // ---------------------------------------------------------------- VPC
    const vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr('10.42.0.0/16'),
      maxAzs: 2,
      natGateways: 0,
      restrictDefaultSecurityGroup: false, // true would add a custom-resource Lambda
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 20, mapPublicIpOnLaunch: true },
      ],
    });
    for (const subnet of vpc.publicSubnets) {
      cdk.Tags.of(subnet).add('kubernetes.io/role/elb', '1');
    }
    const subnetIds = vpc.publicSubnets.map((s) => s.subnetId);

    // ---------------------------------------------------------------- IAM
    const clusterRole = new iam.Role(this, 'ClusterRole', {
      assumedBy: new iam.ServicePrincipal('eks.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSClusterPolicy')],
    });

    const nodeRole = new iam.Role(this, 'NodeRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSWorkerNodePolicy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKS_CNI_Policy'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEC2ContainerRegistryReadOnly'),
      ],
    });

    // ------------------------------------------------------------ Cluster
    const cluster = new eks.CfnCluster(this, 'Cluster', {
      name: appCtx.clusterName,
      version: appCtx.kubernetesVersion,
      roleArn: clusterRole.roleArn,
      resourcesVpcConfig: {
        subnetIds,
        endpointPublicAccess: true,
        endpointPrivateAccess: false,
      },
      accessConfig: {
        authenticationMode: 'API',
        bootstrapClusterCreatorAdminPermissions: false,
      },
      // Control-plane logging disabled (CloudWatch costs).
      logging: { clusterLogging: { enabledTypes: [] } },
      upgradePolicy: { supportType: 'STANDARD' }, // avoid extended-support fees
      // Installs self-managed aws-node / kube-proxy / coredns. aws-node stays self-managed
      // (Helm, scripts/install-cni.sh); kube-proxy and coredns are taken over by the addons below.
      bootstrapSelfManagedAddons: true,
    });
    // Subnets/routes/IGW must exist before the cluster and outlive it on delete.
    cluster.node.addDependency(vpc);

    // ------------------------------------------------------- Access entries
    const roleArn = (name: string) => `arn:aws:iam::${this.account}:role/${name}`;
    const accessEntries: Array<[string, string, string]> = [
      ['AdminAccess', IAM_NAMES.adminRole, 'AmazonEKSClusterAdminPolicy'],
      ['CiAccess', IAM_NAMES.ciRole, 'AmazonEKSClusterAdminPolicy'],
      ['ReadOnlyAccess', IAM_NAMES.readOnlyRole, 'AmazonEKSAdminViewPolicy'],
    ];
    for (const [id, roleName, policy] of accessEntries) {
      new eks.CfnAccessEntry(this, id, {
        clusterName: cluster.ref,
        principalArn: roleArn(roleName),
        type: 'STANDARD',
        accessPolicies: [
          {
            policyArn: `arn:${this.partition}:eks::aws:cluster-access-policy/${policy}`,
            accessScope: { type: 'cluster' },
          },
        ],
      });
    }

    // ------------------------------------------------------------ Add-ons
    // No vpc-cni addon: the CNI is self-managed (see header).
    // Ordering: cluster -> kube-proxy -> nodegroup -> coredns
    // CoreDNS is a Deployment that needs a node to schedule on (addon goes DEGRADED /
    // CFN hangs without one), so it comes after the nodegroup.
    // On destroy the order reverses: coredns -> nodegroup -> kube-proxy -> cluster.
    const addon = (id: string, name: string, configurationValues?: object) =>
      new eks.CfnAddon(this, id, {
        clusterName: cluster.ref,
        addonName: name,
        resolveConflicts: 'OVERWRITE',
        preserveOnDelete: false,
        configurationValues: configurationValues ? JSON.stringify(configurationValues) : undefined,
      });

    const kubeProxy = addon('KubeProxyAddon', 'kube-proxy');

    // ----------------------------------------------------------- Nodegroup
    const nodegroup = new eks.CfnNodegroup(this, 'Nodegroup', {
      clusterName: cluster.ref,
      nodegroupName: `${appCtx.clusterName}-spot`,
      nodeRole: nodeRole.roleArn,
      subnets: subnetIds,
      capacityType: 'SPOT',
      instanceTypes: appCtx.nodeInstanceTypes,
      amiType: 'AL2023_x86_64_STANDARD', // kernel 6.x: eBPF requirements of the network policy agent
      diskSize: 20,
      scalingConfig: { minSize: 1, maxSize: 1, desiredSize: 1 },
      updateConfig: { maxUnavailable: 1 },
    });
    nodegroup.node.addDependency(kubeProxy);

    const coreDns = addon('CoreDnsAddon', 'coredns', { replicaCount: 1 });
    coreDns.node.addDependency(nodegroup);

    // ----------------------------------------------------------------- ECR
    // L2 emptyOnDelete maps to the CFN-native EmptyOnDelete property (no custom resource;
    // only the deprecated autoDeleteImages option uses a Lambda).
    const repo = new ecr.Repository(this, 'NpaRepo', {
      repositoryName: ECR_REPO_NAME,
      imageScanOnPush: false,
      emptyOnDelete: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      lifecycleRules: [{ description: 'Keep last 3 images', maxImageCount: 3 }],
    });

    // ------------------------------------------------------------- Outputs
    new cdk.CfnOutput(this, 'ClusterName', { value: cluster.ref });
    new cdk.CfnOutput(this, 'Region', { value: this.region });
    new cdk.CfnOutput(this, 'UpdateKubeconfigCommand', {
      value: `aws eks update-kubeconfig --region ${this.region} --name ${appCtx.clusterName} --alias ${appCtx.clusterName}`,
    });
    new cdk.CfnOutput(this, 'EcrRepositoryUri', { value: repo.repositoryUri });
    new cdk.CfnOutput(this, 'NodegroupName', { value: nodegroup.attrNodegroupName });
  }
}
