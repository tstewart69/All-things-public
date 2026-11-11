#!/usr/bin/env bash
#
# Builds the pipeline image and deploys it as a Cloud Run Job.
#
# The --set-secrets mapping is generated from Secret Manager itself (every
# secret labelled app=jira-assets-pipeline) rather than hardcoded here, so
# adding a credential means creating a labelled secret and redeploying — there
# is no list in this file to keep in sync. The secret name must match the
# environment variable the scripts read (e.g. CS_CLIENT_ID).

set -euo pipefail

PROJECT="${PROJECT:-your-gcp-project-id}"
REGION="${REGION:-us-central1}"
JOB_NAME="${JOB_NAME:-assets-pipeline}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-assets-pipeline@${PROJECT}.iam.gserviceaccount.com}"

# The CSVs are written to a GCS bucket mounted at OUT_DIR rather than to the
# container's in-memory filesystem, so they survive the execution and can be
# inspected afterwards. OUT_DIR must match the absolute path the Data Manager
# adapters are configured to read from.
BUCKET="${BUCKET:-${PROJECT}-assets-data}"
OUT_DIR="${OUT_DIR:-/mnt/assets-data}"

# gcloud is not always on PATH (e.g. the Homebrew SDK install).
GCLOUD="${GCLOUD_BIN:-gcloud}"
command -v "$GCLOUD" >/dev/null 2>&1 || {
  echo "ERROR: gcloud not found. Set GCLOUD_BIN to its full path." >&2
  exit 1
}

echo "==> Collecting secrets for project $PROJECT"
NAMES=$("$GCLOUD" secrets list \
  --project="$PROJECT" \
  --filter="labels.app=jira-assets-pipeline" \
  --format="value(name)")

if [ -z "$NAMES" ]; then
  echo "ERROR: no secrets labelled app=jira-assets-pipeline. Create them in Secret Manager first." >&2
  exit 1
fi

# Each secret becomes an env var of the same name, pinned to :latest so a
# rotation is picked up by the next execution without redeploying.
SECRET_MAP=""
COUNT=0
for name in $NAMES; do
  SECRET_MAP="${SECRET_MAP:+$SECRET_MAP,}${name}=${name}:latest"
  COUNT=$((COUNT + 1))
done
echo "    $COUNT secrets will be injected as environment variables"

echo "==> Deploying Cloud Run Job '$JOB_NAME' to $REGION"
echo "    CSVs -> gs://$BUCKET mounted at $OUT_DIR"

# gen2 is required for Cloud Storage volume mounts.
"$GCLOUD" run jobs deploy "$JOB_NAME" \
  --source . \
  --project="$PROJECT" \
  --region="$REGION" \
  --service-account="$SERVICE_ACCOUNT" \
  --set-secrets="$SECRET_MAP" \
  --set-env-vars="OUT_DIR=$OUT_DIR" \
  --execution-environment=gen2 \
  --add-volume="name=assets-data,type=cloud-storage,bucket=$BUCKET" \
  --add-volume-mount="volume=assets-data,mount-path=$OUT_DIR" \
  --memory=2Gi \
  --cpu=2 \
  --task-timeout=3600s \
  --max-retries=0 \
  --quiet   # accept the Artifact Registry repo-creation prompt on first deploy

cat <<EOF

===== Deployed =====
Run it now:
  $GCLOUD run jobs execute $JOB_NAME --region $REGION --project $PROJECT --wait

Tail logs:
  $GCLOUD beta run jobs logs tail $JOB_NAME --region $REGION --project $PROJECT
EOF
