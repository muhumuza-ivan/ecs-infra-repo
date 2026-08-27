#!/usr/bin/env bash
# Run this ONCE, locally, using your own already-authenticated AWS session
# (e.g. `aws login` / IAM Identity Center SSO).
# This is an unavoidable manual step in this whole setup:
# something already-trusted by AWS has to create the first trust relationship with GitHub Actions' OIDC provider.
# Nothing here creates or stores a long-lived credential -
# the session is ephemeral and this script touches nothing after it exits.
#
# Everything else - the artifact bucket, ECR repo, SSM parameters, and the
# entire VPC/ALB/ECS/pipeline stack - is created and kept up to date
# automatically by .github/workflows/deploy-infra.yml on every push, using
# the role this script creates.
set -euo pipefail

REGION="eu-west-1"
GITHUB_ORG="muhumuza-ivan"
INFRA_REPO="ecs-infra-repo"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "Account: ${ACCOUNT_ID}"
echo "Checking for existing GitHub OIDC provider..."

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "No GitHub OIDC provider found in this account. Creating it (one-time, this account only)..."
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
fi

echo "Creating the infra-deploy trust role..."
aws cloudformation deploy \
  --stack-name lab-app-infra-deploy-role \
  --template-file templates/infra-deploy-role.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides \
    GitHubOrg="$GITHUB_ORG" \
    InfraRepoName="$INFRA_REPO" \
    GitHubOidcProviderArn="$OIDC_PROVIDER_ARN"

ROLE_ARN="$(aws cloudformation describe-stacks \
  --stack-name lab-app-infra-deploy-role \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='InfraDeployRoleArn'].OutputValue" \
  --output text)"

echo ""
echo "Trust established. Set this one secret, then every future push to this"
echo "repo's main branch is fully automated, with no stored credentials."
echo ""
echo "The whole role ARN is stored as a single secret - the account ID is not a"
echo "repo variable. The workflow reads the account back from the assumed"
echo "session (sts get-caller-identity) when it needs it, so the account lives"
echo "in exactly one place instead of being reassembled from loose pieces:"
echo ""
echo "  gh secret set AWS_INFRA_DEPLOY_ROLE_ARN --body ${ROLE_ARN} --repo ${GITHUB_ORG}/${INFRA_REPO}"
echo ""
echo "The app repo needs the same treatment for its own role, which this repo's"
echo "workflow creates on its first run (templates/oidc-github.yaml):"
echo ""
echo "  gh secret set AWS_GITHUB_ACTIONS_ROLE_ARN \\"
echo "    --body arn:aws:iam::${ACCOUNT_ID}:role/lab-app-github-actions-role \\"
echo "    --repo ${GITHUB_ORG}/ecs-app-repo"
