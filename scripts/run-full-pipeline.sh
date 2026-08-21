#!/bin/bash
# Runs the whole Phase 2 pipeline unattended, overnight, for all 8 recorded
# days. Each step only does work that has not already been done, so this is
# safe to re-run if it gets interrupted partway through.
set -e
cd "/c/Users/nagga/Desktop/WHERE IS MY BUS"

echo "=== $(date) : step 1 - pull all days from the recorder VM ==="
mkdir -p "/c/Users/nagga/Desktop/DATA FOR WIMB/raw" "/c/Users/nagga/Desktop/DATA FOR WIMB/manifest"
cd "/c/Users/nagga/Desktop/DATA FOR WIMB"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519 azureuser@40.123.233.174 \
  'tar -cf - -C /var/lib/bus-data raw manifest' | tar -xf - -C .
cd "/c/Users/nagga/Desktop/WHERE IS MY BUS"

echo "=== $(date) : step 2 - load all frames into Postgres ==="
npm run load-realtime

echo "=== $(date) : step 3 - compute raw distance-along-route for new frames ==="
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -f /db/compute_vehicle_raw_progress_chunked.sql

echo "=== $(date) : step 4 - reset match decisions so every reading is re-checked with the fixed logic ==="
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c \
  "UPDATE vehicle_progress SET accepted=NULL, accepted_dist_along_route_m=NULL, reject_reason=NULL;"

echo "=== $(date) : step 5 - run the matcher (timestamp fix + trip-aware reset + lap-restart fix) ==="
npm run match-vehicle-progress

echo "=== $(date) : step 6 - final numbers ==="
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT count(*) AS total_readings,
       count(*) FILTER (WHERE accepted) AS accepted,
       count(*) FILTER (WHERE NOT accepted) AS rejected,
       round(100.0*count(*) FILTER (WHERE NOT accepted)/count(*),1) AS pct_rejected
FROM vehicle_progress;"
MSYS_NO_PATHCONV=1 docker exec wimb-db psql -U wimb -d wimb -c "
SELECT pg_size_pretty(pg_database_size('wimb')) AS final_db_size;"

echo "=== $(date) : done ==="
