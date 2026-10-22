#!/usr/bin/env bash
set -euo pipefail

SUBMISSION_ROOT=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

cd "${SUBMISSION_ROOT}"/app
mvn package

cd "${SUBMISSION_ROOT}"
mv ./app/target/tds-challenge-vertx-app.jar ./