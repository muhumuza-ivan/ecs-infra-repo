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
