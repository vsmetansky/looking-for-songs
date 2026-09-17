#!/usr/bin/env bash
#
# One-time setup of everything Terraform cannot create for itself: the state
# bucket it stores state in, the identity CI authenticates as, and the secrets
# whose values must never enter Terraform state.
#
# Safe to re-run: every step checks for existing resources first.
#
#   PROJECT_ID=your-project ./scripts/bootstrap.sh
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID, e.g. PROJECT_ID=my-project $0}"
REGION="${REGION:-us-east1}"
SERVICE="${SERVICE:-looking-for-songs}"
GITHUB_REPO="${GITHUB_REPO:-vsmetansky/looking-for-songs}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"
POOL_ID="${POOL_ID:-github}"
PROVIDER_ID="${PROVIDER_ID:-github-oidc}"
SA_ID="${SA_ID:-deployer}"

SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
REPO_OWNER="${GITHUB_REPO%%/*}"

command -v gcloud >/dev/null || {
  echo "gcloud not found: https://cloud.google.com/sdk/docs/install" >&2
  exit 1
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
skip() { printf '    already exists, skipping: %s\n' "$1"; }

# IAM is eventually consistent: a freshly created service account is not
# immediately visible to the policy API, so binding a role to it can fail for
# a few seconds with "does not exist". Retry rather than make the operator
# re-run the script.
retry() {
  local attempts="$1"; shift
  local n=1 out
  while true; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    # Only propagation errors are worth retrying. A bad role name or malformed
    # argument will never succeed, so surface it immediately instead of
    # burning a minute first.
    if ! printf '%s' "$out" | grep -qiE "does not exist|not found|NOT_FOUND"; then
      echo "    not retryable:" >&2
      printf '%s\n' "$out" >&2
      return 1
    fi
    if [ "$n" -ge "$attempts" ]; then
      echo "    failed after ${attempts} attempts:" >&2
      printf '%s\n' "$out" >&2
      return 1
    fi
    printf '    not ready, retrying in 5s (%d/%d)\n' "$n" "$attempts"
    sleep 5
    n=$((n + 1))
  done
}

sa_exists()        { gcloud iam service-accounts describe "$SA_EMAIL"; }
bind_project_role() {
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$1" --condition=None --quiet
}

gcloud config set project "$PROJECT_ID" --quiet

step "Enabling bootstrap APIs"
# Terraform enables the rest; these are the ones needed to get that far.
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  --quiet

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

step "Terraform state bucket: gs://${STATE_BUCKET}"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  skip "gs://${STATE_BUCKET}"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --location="$REGION" --uniform-bucket-level-access
fi
# Versioning lets you recover from a corrupted or truncated state write.
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

step "Artifact Registry repository: ${SERVICE}"
if gcloud artifacts repositories describe "$SERVICE" --location="$REGION" >/dev/null 2>&1; then
  skip "$SERVICE"
else
  gcloud artifacts repositories create "$SERVICE" \
    --repository-format=docker --location="$REGION" \
    --description="Images for ${SERVICE}"
fi

step "Deployer service account: ${SA_EMAIL}"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  skip "$SA_EMAIL"
else
  gcloud iam service-accounts create "$SA_ID" \
    --display-name="Terraform/CI deployer for ${SERVICE}"
  # Block until the policy API can see it.
  retry 12 sa_exists
fi

step "Granting project roles to deployer"
for role in \
  roles/run.admin \
  roles/apigateway.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/serviceusage.serviceUsageAdmin \
  roles/serviceusage.apiKeysAdmin \
  roles/secretmanager.admin \
  roles/artifactregistry.writer
do
  retry 12 bind_project_role "$role"
  printf '    %s\n' "$role"
done

# State access is scoped to the one bucket rather than granted project-wide.
retry 12 gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role=roles/storage.objectAdmin
printf '    roles/storage.objectAdmin (on gs://%s only)\n' "$STATE_BUCKET"

step "Workload Identity pool: ${POOL_ID}"
if gcloud iam workload-identity-pools describe "$POOL_ID" --location=global >/dev/null 2>&1; then
  skip "$POOL_ID"
else
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --location=global --display-name="GitHub Actions"
fi

step "OIDC provider: ${PROVIDER_ID}"
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
     --location=global --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  skip "$PROVIDER_ID"
else
  # The attribute condition is mandatory: without it any GitHub repository on
  # the internet could mint tokens for this pool.
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --location=global --workload-identity-pool="$POOL_ID" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${REPO_OWNER}'"
fi

step "Allowing ${GITHUB_REPO} to impersonate the deployer"
retry 12 gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}" \
  --quiet

step "Spotify secrets"
create_secret() {
  local name="$1"
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    skip "$name"
    return
  fi
  local value
  read -rsp "    value for ${name}: " value
  echo
  # printf, not echo: a trailing newline becomes part of the secret and
  # breaks Spotify's Basic auth header in a confusing way.
  printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --quiet
}
create_secret spotify-client-id
create_secret spotify-client-secret

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

step "Done. Set these GitHub repository variables"
cat <<VARS

  gh variable set GCP_PROJECT_ID  --repo ${GITHUB_REPO} --body "${PROJECT_ID}"
  gh variable set GCP_REGION      --repo ${GITHUB_REPO} --body "${REGION}"
  gh variable set TF_STATE_BUCKET --repo ${GITHUB_REPO} --body "${STATE_BUCKET}"
  gh variable set WIF_PROVIDER    --repo ${GITHUB_REPO} --body "${WIF_PROVIDER}"
  gh variable set DEPLOYER_SA     --repo ${GITHUB_REPO} --body "${SA_EMAIL}"

If the Cloud Run service already exists from a console deploy, adopt it before
the first push, or Terraform will fail trying to create it:

  cd terraform
  terraform init -backend-config="bucket=${STATE_BUCKET}"
  terraform import -var="project_id=${PROJECT_ID}" -var="image=placeholder" \\
    google_cloud_run_v2_service.app \\
    projects/${PROJECT_ID}/locations/${REGION}/services/${SERVICE}

VARS
