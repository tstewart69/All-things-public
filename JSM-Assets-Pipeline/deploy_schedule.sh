#!/usr/bin/env bash
#
# Creates or updates the Cloud Scheduler trigger for the assets pipeline.
#
# Cloud Scheduler invokes the Cloud Run Admin API's :run endpoint, which starts
# an execution and returns immediately. Two consequences worth remembering:
#
#   * Auth must be --oauth-... (a Google API access token), not --oidc-...
#     OIDC is for invoking a Cloud Run *service* URL and returns 401 here.
#   * Scheduler reports success once the execution is *created*, not when the
#     pipeline finishes. It is not a health signal — failures surface through
#     a Cloud Monitoring alert on failed job executions instead.

set -euo pipefail

PROJECT="${PROJECT:-your-gcp-project-id}"
REGION="${REGION:-us-central1}"
JOB_NAME="${JOB_NAME:-assets-pipeline}"
SCHEDULER_JOB="${SCHEDULER_JOB:-assets-pipeline-weekdays-6pm}"
SCHEDULE="${SCHEDULE:-0 18 * * 1-5}"
TIME_ZONE="${TIME_ZONE:-America/Denver}"
SA="${SA:-assets-pipeline@${PROJECT}.iam.gserviceaccount.com}"

GCLOUD="${GCLOUD_BIN:-gcloud}"
command -v "$GCLOUD" >/dev/null 2>&1 || {
  echo "ERROR: gcloud not found. Set GCLOUD_BIN to its full path." >&2
  exit 1
}

URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB_NAME}:run"

if "$GCLOUD" scheduler jobs describe "$SCHEDULER_JOB" \
     --location="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  echo "==> Updating existing scheduler job '$SCHEDULER_JOB'"
  ACTION=update
else
  echo "==> Creating scheduler job '$SCHEDULER_JOB'"
  ACTION=create
fi

"$GCLOUD" scheduler jobs "$ACTION" http "$SCHEDULER_JOB" \
  --project="$PROJECT" \
  --location="$REGION" \
  --schedule="$SCHEDULE" \
  --time-zone="$TIME_ZONE" \
  --uri="$URI" \
  --http-method=POST \
  --oauth-service-account-email="$SA" \
  --quiet >/dev/null

"$GCLOUD" scheduler jobs describe "$SCHEDULER_JOB" \
  --location="$REGION" --project="$PROJECT" \
  --format="value[separator='  |  '](state,schedule,timeZone,scheduleTime)"

cat <<EOF

Pause / resume:
  $GCLOUD scheduler jobs pause  $SCHEDULER_JOB --location=$REGION --project=$PROJECT
  $GCLOUD scheduler jobs resume $SCHEDULER_JOB --location=$REGION --project=$PROJECT
EOF
