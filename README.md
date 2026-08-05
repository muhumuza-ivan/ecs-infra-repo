# Lab Guide: Highly Available, Blue/Green ECS Fargate Deployment with CloudFormation GitSync + OIDC CI/CD

This guide walks through every step needed to satisfy the project's functional, technical, and rubric requirements. It's organized so you can work top-to-bottom and check off rubric items as you go.

---

## 0. Architecture Overview

```
GitHub (app repo) --push--> GitHub Actions (OIDC) --build/push--> ECR
                                                                    |
                                                              EventBridge rule
                                                                    |
                                                                    v
                                                             CodePipeline
                                                                    |
                                                                    v
                                                  CodeDeploy (ECS Blue/Green)
                                                                    |
                                                                    v
   Internet --> ALB (public subnets) --> Target Group (Blue/Green) --> ECS Fargate tasks (private subnets)
                                                                              |
                                                                    VPC Endpoints --> ECR, S3, CloudWatch Logs
```

Two GitHub repos:
1. **`infra-repo`** — all CloudFormation templates, deployed via CloudFormation GitSync.
2. **`app-repo`** — Java app source, Dockerfile, buildspec, GitHub Actions workflow.

Two AZs minimum, each with a public subnet (ALB, NAT Gateway) and a private subnet (ECS tasks, VPC endpoints).

---

## 1. Prerequisites

- AWS account with admin access to bootstrap OIDC/roles once (afterward CI/CD uses least-privilege roles).
- Two GitHub repos created: `infra-repo`, `app-repo`.
- AWS CLI, Docker, and a Java toolchain (e.g., Java 21 + Maven or Spring Boot) installed locally for initial testing.
- Region chosen for the whole lab (e.g., `eu-west-1`) — use consistently everywhere.

---

## 2. Repository Layout

### `app-repo`
```
app-repo/
├── src/main/java/.../Application.java
├── src/main/resources/static/index.html
├── pom.xml
├── Dockerfile
├── appspec.yaml              # CodeDeploy ECS spec
├── taskdef.json              # ECS task definition template (used by CodeDeploy)
└── .github/workflows/build-and-push.yml
```

### `infra-repo`
```
infra-repo/
├── templates/
│   ├── main.yaml              # root/parent stack
│   ├── network.yaml           # VPC, subnets, NAT, routes, endpoints
│   ├── security-groups.yaml
│   ├── ecr.yaml
│   ├── ecs-cluster-service.yaml
│   ├── alb.yaml
│   ├── codepipeline-codedeploy.yaml
│   ├── eventbridge.yaml
│   ├── oidc-github.yaml
│   └── artifact-bucket.yaml
└── gitsync-config/ (or configured directly in CFN console/CLI)
```

---

## 3. Step 1 — Application Code (Frontend Requirement)

Build a minimal Java web app (Spring Boot is simplest) that serves a static page.

**`src/main/resources/static/index.html`**
```html
<!DOCTYPE html>
<html>
<head><title>ECS Fargate Lab</title></head>
<body style="font-family: sans-serif; text-align:center; margin-top:100px;">
  <h1>Your Full Name</h1>
  <h2>Lab Name: ECS Fargate Blue/Green CI/CD Lab</h2>
</body>
</html>
```

Replace "Your Full Name" and confirm the lab name matches your assignment title. If using Spring Boot, this file under `src/main/resources/static/` is served automatically at `/`.

Add a `/health` endpoint (or rely on `/` for the ALB health check — Spring Boot serves static content at `/` with HTTP 200, which works fine as a health check target).

**`pom.xml`** — standard `spring-boot-starter-web` app packaged as an executable jar, exposing port 8080.

---

## 4. Step 2 — Dockerfile

```dockerfile
# ---- Build stage ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -q clean package -DskipTests

# ---- Runtime stage ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Test locally:
```bash
docker build -t lab-app:local .
docker run -p 8080:8080 lab-app:local
curl http://localhost:8080
```

---

## 5. Step 3 — OIDC Trust Between GitHub and AWS

This removes the need for long-lived AWS access keys in GitHub Actions.

**`templates/oidc-github.yaml`** (deploy this first, or as part of `main.yaml`):

```yaml
Parameters:
  GitHubOrg:
    Type: String
  AppRepoName:
    Type: String

Resources:
  GitHubOIDCProvider:
    Type: AWS::IAM::OIDCProvider
    Properties:
      Url: https://token.actions.githubusercontent.com
      ClientIdList:
        - sts.amazonaws.com
      ThumbprintList:
        - 6938fd4d98bab03faadb97b34396831e3780aea1

  GitHubActionsRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: github-actions-ecr-push-role
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Federated: !Ref GitHubOIDCProvider
            Action: sts:AssumeRoleWithWebIdentity
            Condition:
              StringEquals:
                token.actions.githubusercontent.com:aud: sts.amazonaws.com
              StringLike:
                token.actions.githubusercontent.com:sub: !Sub "repo:${GitHubOrg}/${AppRepoName}:ref:refs/heads/main"
      Policies:
        - PolicyName: ecr-push
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - ecr:GetAuthorizationToken
                Resource: "*"
              - Effect: Allow
                Action:
                  - ecr:BatchCheckLayerAvailability
                  - ecr:PutImage
                  - ecr:InitiateLayerUpload
                  - ecr:UploadLayerPart
                  - ecr:CompleteLayerUpload
                Resource: !GetAtt ECRRepository.Arn
```

> Rubric hit: **OIDC used for AWS authentication (10 pts)**. Scope the trust policy's `sub` condition tightly to your repo and branch — this satisfies least-privilege.

---

## 6. Step 4 — Networking (Multi-AZ VPC)

**`templates/network.yaml`** highlights:

- 1 VPC (e.g., `10.0.0.0/16`)
- 2 public subnets (one per AZ), 2 private subnets (one per AZ)
- 1 Internet Gateway attached to the VPC
- NAT Gateway(s) in public subnets (one per AZ for HA, or one shared to save cost — note the tradeoff in your writeup for the "cost optimization" extra credit)
- Route tables: public subnets → IGW; private subnets → NAT
- **VPC Endpoints** (Interface type, in private subnets) for:
  - `com.amazonaws.<region>.ecr.api`
  - `com.amazonaws.<region>.ecr.dkr`
  - `com.amazonaws.<region>.logs` (CloudWatch Logs)
  - `com.amazonaws.<region>.s3` (Gateway endpoint — required because ECR image layers are stored in S3)
  - Optionally `com.amazonaws.<region>.secretsmanager` if you add secrets later

```yaml
  ECRApiEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ecr.api
      VpcEndpointType: Interface
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref VPCEndpointSecurityGroup]
      PrivateDnsEnabled: true

  ECRDkrEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub com.amazonaws.${AWS::Region}.ecr.dkr
      VpcEndpointType: Interface
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref VPCEndpointSecurityGroup]
      PrivateDnsEnabled: true

  LogsEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub com.amazonaws.${AWS::Region}.logs
      VpcEndpointType: Interface
      SubnetIds: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
      SecurityGroupIds: [!Ref VPCEndpointSecurityGroup]
      PrivateDnsEnabled: true

  S3GatewayEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref VPC
      ServiceName: !Sub com.amazonaws.${AWS::Region}.s3
      VpcEndpointType: Gateway
      RouteTableIds: [!Ref PrivateRouteTable1, !Ref PrivateRouteTable2]
```

> Rubric hit: **Multi-AZ VPC (10 pts)**, **Private ECS tasks with VPC Endpoint connectivity (10 pts)**.

---

## 7. Step 5 — Security Groups (Least Privilege)

**`templates/security-groups.yaml`**:

- **ALB SG**: Inbound 80/443 from `0.0.0.0/0`. Outbound to ECS SG only (or all, restricted to task port).
- **ECS Tasks SG**: Inbound on container port (e.g., 8080) **only from ALB SG** (not from `0.0.0.0/0`). No inbound from the internet — tasks are private.
- **VPC Endpoint SG**: Inbound 443 **only from ECS Tasks SG**.

```yaml
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ALB SG - public HTTP/HTTPS
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0

  ECSTaskSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ECS tasks - only from ALB
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 8080
          ToPort: 8080
          SourceSecurityGroupId: !Ref ALBSecurityGroup

  VPCEndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: VPC endpoints - only from ECS tasks
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          SourceSecurityGroupId: !Ref ECSTaskSecurityGroup
```

> Rubric hit: **Security groups follow least-privilege (10 pts)**.

---

## 8. Step 6 — ECR Repository

**`templates/ecr.yaml`**:

```yaml
  ECRRepository:
    Type: AWS::ECR::Repository
    Properties:
      RepositoryName: lab-app
      ImageTagMutability: MUTABLE
      ImageScanningConfiguration:
        ScanOnPush: true
      LifecyclePolicy:
        LifecyclePolicyText: |
          {
            "rules": [{
              "rulePriority": 1,
              "description": "Keep last 10 images",
              "selection": { "tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 10 },
              "action": { "type": "expire" }
            }]
          }
```

**Tagging strategy** (rubric asks for "consistent and mutable"): tag every image with the Git SHA **and** move a `latest` (or `stable`) tag to point at it, e.g., in GitHub Actions:
```bash
docker tag lab-app:$GITHUB_SHA <account>.dkr.ecr.<region>.amazonaws.com/lab-app:$GITHUB_SHA
docker tag lab-app:$GITHUB_SHA <account>.dkr.ecr.<region>.amazonaws.com/lab-app:latest
docker push <account>.dkr.ecr.<region>.amazonaws.com/lab-app:$GITHUB_SHA
docker push <account>.dkr.ecr.<region>.amazonaws.com/lab-app:latest
```
Keep `ImageTagMutability: MUTABLE` so `latest` can be overwritten — this is what "consistent and mutable" is asking for, while the SHA tag gives you an immutable audit trail per build.

> Rubric hit: **Image tagging strategy consistent and mutable (5 pts)**.

---

## 9. Step 7 — ALB, Target Groups (Blue/Green pair), Listener

**`templates/alb.yaml`**:

- 1 ALB in the two **public** subnets, SG = ALB SG.
- **Two target groups** (`tg-blue`, `tg-green`) — CodeDeploy needs two target groups to shift traffic between.
- 1 listener on port 80 forwarding to `tg-blue` initially (CodeDeploy will manage the swap).
- Health check path `/`, healthy threshold 2, interval 15s.

```yaml
  ALB:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Scheme: internet-facing
      Subnets: [!Ref PublicSubnet1, !Ref PublicSubnet2]
      SecurityGroups: [!Ref ALBSecurityGroup]

  TargetGroupBlue:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Port: 8080
      Protocol: HTTP
      TargetType: ip
      VpcId: !Ref VPC
      HealthCheckPath: /
      HealthCheckIntervalSeconds: 15
      HealthyThresholdCount: 2

  TargetGroupGreen:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Port: 8080
      Protocol: HTTP
      TargetType: ip
      VpcId: !Ref VPC
      HealthCheckPath: /
      HealthCheckIntervalSeconds: 15
      HealthyThresholdCount: 2

  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref ALB
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroupBlue
```

> Rubric hit: **Public ALB architecture (part of the 10 pts above)**, **Application accessible via ALB (5 pts)**, **ECS tasks pass ALB health checks (5 pts)**.

---

## 10. Step 8 — ECS Cluster, Task Definition, Service (CodeDeploy-controlled)

**`templates/ecs-cluster-service.yaml`**:

- Fargate cluster.
- Task execution role (pull from ECR, write logs) and task role (app permissions, minimal/none).
- Task definition: container port 8080, `awslogs` log driver pointing to a CloudWatch Logs group.
- Service:
  - `LaunchType: FARGATE`
  - `NetworkConfiguration`: private subnets, `AssignPublicIp: DISABLED`, SG = ECS Task SG.
  - `DeploymentController.Type: CODE_DEPLOY` (critical — this hands blue/green traffic-shifting to CodeDeploy instead of ECS's native rolling update).
  - `DesiredCount: 1`.

```yaml
  ECSCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: lab-app-cluster

  LogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /ecs/lab-app
      RetentionInDays: 14

  TaskDefinition:
    Type: AWS::ECS::TaskDefinition
    Properties:
      Family: lab-app
      Cpu: "256"
      Memory: "512"
      NetworkMode: awsvpc
      RequiresCompatibilities: [FARGATE]
      ExecutionRoleArn: !GetAtt ExecutionRole.Arn
      TaskRoleArn: !GetAtt TaskRole.Arn
      ContainerDefinitions:
        - Name: lab-app
          Image: !Sub "${ECRRepositoryUri}:latest"
          PortMappings:
            - ContainerPort: 8080
          LogConfiguration:
            LogDriver: awslogs
            Options:
              awslogs-group: !Ref LogGroup
              awslogs-region: !Ref AWS::Region
              awslogs-stream-prefix: ecs

  ECSService:
    Type: AWS::ECS::Service
    Properties:
      Cluster: !Ref ECSCluster
      DesiredCount: 1
      LaunchType: FARGATE
      TaskDefinition: !Ref TaskDefinition
      DeploymentController:
        Type: CODE_DEPLOY
      NetworkConfiguration:
        AwsvpcConfiguration:
          Subnets: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
          SecurityGroups: [!Ref ECSTaskSecurityGroup]
          AssignPublicIp: DISABLED
      LoadBalancers:
        - ContainerName: lab-app
          ContainerPort: 8080
          TargetGroupArn: !Ref TargetGroupBlue
```

> Rubric hit: **ECS logs visible in CloudWatch Logs (5 pts)**.

### Auto Scaling (min 1 / desired 1 / max 4, CPU-based)

```yaml
  ScalableTarget:
    Type: AWS::ApplicationAutoScaling::ScalableTarget
    Properties:
      ServiceNamespace: ecs
      ResourceId: !Sub service/${ECSCluster}/${ECSService.Name}
      ScalableDimension: ecs:service:DesiredCount
      MinCapacity: 1
      MaxCapacity: 4
      RoleARN: !Sub arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService

  CPUScalingPolicy:
    Type: AWS::ApplicationAutoScaling::ScalingPolicy
    Properties:
      PolicyName: cpu-target-tracking
      PolicyType: TargetTrackingScaling
      ScalingTargetId: !Ref ScalableTarget
      TargetTrackingScalingPolicyConfiguration:
        TargetValue: 50.0
        PredefinedMetricSpecification:
          PredefinedMetricType: ECSServiceAverageCPUUtilization
        ScaleInCooldown: 60
        ScaleOutCooldown: 60
```

> Rubric hit: **Auto Scaling configured correctly (5 pts)**.

---

## 11. Step 9 — CodeDeploy Application + Deployment Group (ECS Blue/Green)

**`templates/codepipeline-codedeploy.yaml`** (part 1):

```yaml
  CodeDeployApplication:
    Type: AWS::CodeDeploy::Application
    Properties:
      ComputePlatform: ECS

  CodeDeployDeploymentGroup:
    Type: AWS::CodeDeploy::DeploymentGroup
    Properties:
      ApplicationName: !Ref CodeDeployApplication
      DeploymentGroupName: lab-app-dg
      ServiceRoleArn: !GetAtt CodeDeployServiceRole.Arn
      DeploymentConfigName: CodeDeployDefault.ECSAllAtOnce
      DeploymentStyle:
        DeploymentType: BLUE_GREEN
        DeploymentOption: WITH_TRAFFIC_CONTROL
      BlueGreenDeploymentConfiguration:
        TerminateBlueInstancesOnDeploymentSuccess:
          Action: TERMINATE
          TerminationWaitTimeInMinutes: 5
        DeploymentReadyOption:
          ActionOnTimeout: CONTINUE_DEPLOYMENT
      LoadBalancerInfo:
        TargetGroupPairInfoList:
          - ProdTrafficRoute:
              ListenerArns: [!Ref Listener]
            TargetGroups:
              - Name: !GetAtt TargetGroupBlue.TargetGroupName
              - Name: !GetAtt TargetGroupGreen.TargetGroupName
      ECSServices:
        - ServiceName: !GetAtt ECSService.Name
          ClusterName: !Ref ECSCluster
```

App repo needs `appspec.yaml` (drives CodeDeploy's ECS blue/green swap):
```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "lab-app"
          ContainerPort: 8080
```
(`<TASK_DEFINITION>` is substituted by CodePipeline's Deploy action at runtime with the newly registered task definition ARN.)

> Rubric hit: **Blue/green deployment functions correctly (5 pts)**.

---

## 12. Step 10 — S3 Bucket for Nested Templates + Pipeline Artifacts

```yaml
  ArtifactBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub lab-app-artifacts-${AWS::AccountId}-${AWS::Region}
      VersioningConfiguration:
        Status: Enabled
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
```

Upload nested child templates here before deploying `main.yaml`:
```bash
aws s3 cp templates/ s3://lab-app-artifacts-<account>-<region>/templates/ --recursive --exclude "main.yaml"
```
`main.yaml` then references children via `TemplateURL: https://<bucket>.s3.<region>.amazonaws.com/templates/network.yaml`, etc.

---

## 13. Step 11 — CodePipeline (Source = ECR via EventBridge, Deploy = CodeDeploy)

```yaml
  Pipeline:
    Type: AWS::CodePipeline::Pipeline
    Properties:
      RoleArn: !GetAtt PipelineServiceRole.Arn
      ArtifactStore:
        Type: S3
        Location: !Ref ArtifactBucket
      Stages:
        - Name: Source
          Actions:
            - Name: ECRSource
              ActionTypeId:
                Category: Source
                Owner: AWS
                Provider: ECR
                Version: "1"
              Configuration:
                RepositoryName: !Ref ECRRepository
                ImageTag: latest
              OutputArtifacts: [Name: SourceOutput]
        - Name: Deploy
          Actions:
            - Name: DeployToECS
              ActionTypeId:
                Category: Deploy
                Owner: AWS
                Provider: CodeDeployToECS
                Version: "1"
              Configuration:
                ApplicationName: !Ref CodeDeployApplication
                DeploymentGroupName: !Ref CodeDeployDeploymentGroup
                TaskDefinitionTemplateArtifact: SourceOutput
                TaskDefinitionTemplatePath: taskdef.json
                AppSpecTemplateArtifact: SourceOutput
                AppSpecTemplatePath: appspec.yaml
              InputArtifacts: [Name: SourceOutput]
```

> Note: the ECR source action alone only reacts if you also enable/rely on the CloudWatch Events integration; the requirement explicitly wants **EventBridge** to trigger the pipeline, so build the EventBridge rule explicitly in the next step for a clean, visible trigger (and don't rely solely on the built-in polling).

---

## 14. Step 12 — EventBridge Rule: ECR Push → CodePipeline

**`templates/eventbridge.yaml`**:

```yaml
  ECRPushRule:
    Type: AWS::Events::Rule
    Properties:
      Description: Trigger pipeline on new image push to ECR
      EventPattern:
        source: ["aws.ecr"]
        detail-type: ["ECR Image Action"]
        detail:
          action-type: ["PUSH"]
          repository-name: [!Ref ECRRepository]
          result: ["SUCCESS"]
      Targets:
        - Arn: !Sub arn:aws:codepipeline:${AWS::Region}:${AWS::AccountId}:${Pipeline}
          Id: CodePipelineTarget
          RoleArn: !GetAtt EventBridgeInvokePipelineRole.Arn

  EventBridgeInvokePipelineRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: events.amazonaws.com }
            Action: sts:AssumeRole
      Policies:
        - PolicyName: start-pipeline
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action: codepipeline:StartPipelineExecution
                Resource: !Sub arn:aws:codepipeline:${AWS::Region}:${AWS::AccountId}:${Pipeline}
```

> Rubric hit: this is the core mechanism tying "GitHub Actions builds image → EventBridge → CodePipeline → CodeDeploy blue/green" together.

---

## 15. Step 13 — GitHub Actions Workflow (OIDC → Build → Push)

**`.github/workflows/build-and-push.yml`** in `app-repo`:

```yaml
name: Build and Push to ECR

on:
  push:
    branches: [main]

permissions:
  id-token: write   # required for OIDC
  contents: read

env:
  AWS_REGION: eu-west-1
  ECR_REPOSITORY: lab-app

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-ecr-push-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr-login
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        env:
          REGISTRY: ${{ steps.ecr-login.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker tag $REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $REGISTRY/$ECR_REPOSITORY:latest
          docker push $REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $REGISTRY/$ECR_REPOSITORY:latest
```

> Rubric hit: **GitHub Actions builds container image successfully (5 pts)**, **Image pushed to ECR (5 pts)**, **OIDC used for AWS authentication (10 pts)**.

---

## 16. Step 14 — CloudFormation GitSync Setup

GitSync lets CloudFormation deploy stacks directly from `infra-repo` commits (no manual `aws cloudformation deploy`).

1. In the CloudFormation console, choose **Create stack → With new resources → Template is ready → Sync from Git**.
2. Connect GitHub (via **AWS CodeConnections/CodeStar Connections** — you'll authorize AWS to access `infra-repo`).
3. Select the branch (e.g., `main`) and the path to `templates/main.yaml`.
4. Enable **"Deploy stacks automatically"** so every push to `main` in `infra-repo` re-deploys the stack.
5. Confirm IAM role / deployment permissions CloudFormation should assume (create a dedicated GitSync execution role scoped to the resources this lab creates).
6. Push a commit to `infra-repo` and confirm in the CloudFormation console that a new stack update kicks off automatically.

> Rubric hit: **All resources provisioned via CloudFormation GitSync (10 pts)**. Make sure literally everything (VPC, SGs, ECR, pipeline, artifact bucket, EventBridge, OIDC role) lives in these templates — nothing clicked manually in the console outside of the one-time GitSync connection setup itself.

---

## 17. Step 15 — Deploy Order (First-Time Bootstrap)

Because of chicken-and-egg dependencies (ECR must exist before the first image push; the pipeline needs an image to exist before its first successful run), deploy in this order:

1. `oidc-github.yaml` (or include first in `main.yaml`) → creates OIDC provider + GitHub Actions role.
2. `network.yaml` → VPC/subnets/endpoints.
3. `security-groups.yaml`.
4. `ecr.yaml`.
5. Push app code once via GitHub Actions → confirms image lands in ECR with tag `latest`.
6. `alb.yaml`, `ecs-cluster-service.yaml` (task def references the now-existing `:latest` image), `codepipeline-codedeploy.yaml`, `eventbridge.yaml`.
7. Confirm ECS service reaches steady state and ALB target group shows healthy targets.
8. Push a code change → GitHub Actions builds new image → EventBridge fires → CodePipeline runs → CodeDeploy blue/green swap executes → verify old (blue) tasks drain and new (green) tasks serve traffic.

If you want this fully expressed as one `main.yaml` nested-stack deploy, still push a placeholder image to ECR manually once before the very first GitSync deploy, since the task definition needs a real image URI to be valid.

---

## 18. Step 16 — Validation Checklist (map directly to rubric)

| Check | How to verify |
|---|---|
| Multi-AZ VPC | Console → VPC → confirm subnets span 2 AZs |
| Private ECS tasks | ECS service → Networking → `AssignPublicIp: DISABLED`, subnets are private |
| VPC Endpoint connectivity | Task launches successfully without a NAT-dependent public IP; check endpoint DNS resolves in VPC |
| SG least privilege | Inspect each SG's inbound rules — no `0.0.0.0/0` except the ALB |
| GitSync | Push a trivial infra change, confirm auto-deploy in CFN console |
| GitHub Actions build | Push to `app-repo`, check Actions tab succeeds |
| Image in ECR | `aws ecr describe-images --repository-name lab-app` |
| OIDC | Confirm no AWS access key secrets exist in `app-repo` GitHub secrets |
| Tagging strategy | Each image has a SHA tag + `latest` |
| ALB reachable | `curl http://<alb-dns-name>` returns your name + lab name |
| ALB health checks | Target group → Targets tab → status `healthy` |
| CloudWatch Logs | `/ecs/lab-app` log group has recent streams |
| Auto Scaling | `aws application-autoscaling describe-scaling-policies` shows target-tracking on CPU, min 1 / max 4 |
| Blue/green works | Push new image, watch CodeDeploy console show a blue/green deployment progress and complete |

---

## 19. Step 17 — Network Architecture Diagram

Use one of:
- **draw.io** (diagrams.net) — manually lay out VPC, 2 AZs, public/private subnets, IGW, NAT, ALB, ECS tasks, VPC endpoints, ECR, CodePipeline/CodeDeploy, EventBridge, GitHub.
- **Diagram-as-code**: Python [`diagrams`](https://diagrams.mingrammer.com/) library (`pip install diagrams`, requires Graphviz) — lets you check the diagram into `infra-repo` and regenerate it in CI.

Minimum elements to include: VPC boundary, 2 AZs, public/private subnet split, IGW, NAT Gateway, ALB, ECS Fargate tasks, VPC Endpoints, ECR, EventBridge, CodePipeline, CodeDeploy, GitHub Actions/OIDC arrow into AWS.

---

## 20. Extra Credit — Tagging & Cost/Security Best Practices

- Add a common `Tags` block (e.g., `Project: ecs-fargate-lab`, `Environment: dev`, `Owner: <your name>`) to every resource that supports `Tags`, or set **stack-level tags** on `main.yaml` so CloudFormation propagates them to all supported child resources.
- Cost: consider a single NAT Gateway shared across AZs for this lab (documented tradeoff vs. one-per-AZ HA), Fargate Spot for non-critical scaling capacity, ECR lifecycle policy (already added above) to avoid unbounded image storage cost.
- Security: enable ECR image scanning (already set `ScanOnPush: true`), enable S3 bucket encryption + block public access (already set), restrict the GitHub OIDC trust policy's `sub` claim to the exact repo/branch, avoid `AdministratorAccess` on any pipeline/service role — scope IAM policies to only the actions listed above.

---

## 21. Deliverables Checklist

- [ ] `infra-repo` link — CloudFormation templates, GitSync-connected.
- [ ] `app-repo` link — Java source, Dockerfile, `appspec.yaml`, `taskdef.json`, GitHub Actions workflow.
- [ ] ALB DNS name (from `aws elbv2 describe-load-balancers` or the CFN stack outputs).
- [ ] Architecture diagram (draw.io export or diagrams-as-code output), committed to `infra-repo`.