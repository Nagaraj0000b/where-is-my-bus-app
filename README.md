# Where Is My Bus

**Bus tracking, arrival ranges, and journey planning for Delhi — with an offline SQLite transit pack when the network drops.**

Where Is My Bus is built on Delhi's Open Transit Data (OTD) static GTFS and GTFS-Realtime feeds. It maps recorded bus positions onto route shapes, derives empirical segment travel times, returns calibrated arrival windows with data-source provenance, plans A-to-B journeys ranked by total travel time, and bundles an offline SQLite pack for stop search, route lookup, and direct-bus queries without connectivity.

> **Live feed status:** The realtime feed recorder is paused after capturing a 7-day archive (10–16 August 2026). The backend serves historical ETAs, journey planning, crowdsourced passenger beacons, simulated GNSS location proofs, and recorded stop-passage replay.

---

## Key Features

- **Stop Board (`Board` tab):** Shows nearest stops, arriving buses with time ranges, source badges, destination filtering (`Where to?`), and recorded-moment replay.
- **Live Ride Tracking:** Interactive OpenStreetMap (`flutter_map`) view following the selected bus with direction, next stop, arrival window, progress ribbon, arrival alarm, and optional passenger beacon sharing (*"I'm on this bus"*).
- **Journey Planner (`Plan` tab):** Plans A-to-B trips (direct or up to 1 transfer) ranked by walk + wait + ride time, plus an hour-by-hour comparison (`05:00–23:00`).
- **Saved & Profile (`Saved` / `You` tabs):** Saved stops/routes, arrival alarm controls, contribution stats, and optional JWT sign-in (all transit features work signed out).
- **Offline Transit Pack:** Bundled SQLite database (`app/assets/data/wimb_offline.db`) powering stop search, route search, ordered stop lists, and direct-bus lookups offline.
- **Crowdsourced Telemetry & Location Proofs (API):** `POST /crowdsource/ping` validates passenger beacons (`5–80 km/h`, `≤ 50 m` off-route) with multi-rider consensus; `/location-proof` and `/relay-selection` attach simulated four-satellite location proofs in the API.

---

## Tech Stack

- **Mobile App (`app/`):** Flutter (Dart), Riverpod, `flutter_map` + OpenStreetMap, `sqflite` / `sqflite_common_ffi`, `geolocator`
- **Backend API (`api/`):** Node.js 25+ (native TypeScript execution), Fastify, `pg`, `bcryptjs`, `jsonwebtoken`
- **Database (`db/`):** PostgreSQL 17 + PostGIS 3.5 (Docker Compose + Adminer)

---

## Prerequisites

- **Docker Desktop** (PostgreSQL 17 + PostGIS 3.5 + Adminer)
- **Node.js 22.18+** (tested on Node 25)
- **Python 3** (used by `export-offline` to compile the SQLite pack)
- **Flutter SDK 3.47+** (for running/building the mobile or web app)
- **Static GTFS snapshot** extracted into `delhi_buses_static_gtfs_v1/` (from [OTD Delhi static data](https://otd.delhi.gov.in/data/static))

---

## Quickstart

### 1. Configure environment & install dependencies

```bash
cp .env.example .env      # PowerShell: Copy-Item .env.example .env
npm install
```

Key variables in `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `API_BASE` | `http://127.0.0.1:3000` | Backend URL baked into Flutter at build time |
| `PORT` | `3000` | Fastify API port |
| `DATABASE_URL` | `postgres://wimb:wimb_local_dev@localhost:5432/wimb` | PostgreSQL connection string |
| `JWT_SECRET` | *(dev fallback)* | Secret for signing auth tokens |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_PORT` | `wimb` / `wimb` / `wimb_local_dev` / `5432` | Docker Postgres settings |
| `DATA_ROOT` | `./data` | Path to recorded `.pb.gz` archive (for historical pipeline) |

### 2. Start the database and load static GTFS

```bash
docker compose up -d --wait

docker exec wimb-db psql -U wimb -d wimb -f /db/schema.sql
docker exec wimb-db psql -U wimb -d wimb -v label=delhi_buses_static_gtfs_v1 -f /db/load.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/verify.sql

# Required schema structures
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_travel_times.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_stop_passages.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_auth.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_ui.sql
```

> **Windows Git Bash users:** Prefix `docker exec` commands with `MSYS_NO_PATHCONV=1` so `/db/...` paths are not rewritten.
>
> **Adminer:** Available at `http://localhost:8081` (`System: PostgreSQL`, `Server: db`, `User: wimb`, `Password: wimb_local_dev`, `Database: wimb`).

### 3. Build the offline SQLite pack & run the Flutter app

```bash
docker exec wimb-db psql -U wimb -d wimb -f /db/compute_stop_distances.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_stop_places.sql
npm run export-offline
```

This generates `app/assets/data/wimb_offline.db`. Then run the app:

```bash
cd app
flutter pub get
flutter run --dart-define-from-file=../.env
```

To build a release Android APK:

```bash
cd app
flutter build apk --release --dart-define-from-file=../.env
```

### 4. Start the API

From the repository root:

```bash
npm run api
```

Verify it is running:

```bash
curl http://localhost:3000/health
curl "http://localhost:3000/stops/search?q=Nehru"
curl "http://localhost:3000/routes/search?q=764"
```

### One-click local stack on Windows

`start-all.bat` starts Docker Desktop, Postgres/PostGIS (`wimb-db`), the Fastify API (`:3000`), and an ngrok tunnel (`wimb-ngrok`, using `.ngrok-token` or `NGROK_AUTHTOKEN`):

```bat
start-all.bat
```

### 5. (Optional) Build the historical travel-time layer

If you have the recorded `.pb.gz` archive at `DATA_ROOT`:

```bash
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_realtime.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_matching.sql

bash scripts/process-week.sh
docker exec wimb-db psql -U wimb -d wimb -f /db/compute_travel_times.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_route_places.sql
docker exec wimb-db psql -U wimb -d wimb -f /db/schema_place_frequency.sql
```

---

## API Endpoints

See [api/README.md](api/README.md) for detailed request/response shapes.

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Service and database health check |
| `GET` | `/stats` | Static, realtime, and segment counts |
| `GET` | `/feed/status` | Live feed status and replayable days |
| `GET` | `/stops/near` | Nearest physical stop places for coordinates |
| `GET` | `/stops/search` | Search stops/places by name |
| `GET` | `/stops/:placeId/arrivals` | Arriving buses at a stop (supports `at` replay & `to` destination filter) |
| `GET` | `/routes/search` | Search routes by number/name |
| `GET` | `/routes/:routeId/stops` | Ordered stops along a route |
| `GET` | `/routes/:routeId/detail` | Route shape, stops, active/replayed buses, and ETAs |
| `GET` | `/eta` | Empirical arrival window between two stop sequences on a route |
| `GET` | `/journey` | Ranked A-to-B journeys (up to 1 transfer) |
| `GET` | `/journey/by-hour` | Journey cost comparison across service hours |
| `POST` | `/crowdsource/ping` | Submit a passenger GPS beacon |
| `GET` | `/routes/:id/crowdsourced` | Active crowdsourced vehicles on a route |
| `GET` | `/location-proof` | Simulated four-satellite GNSS location proof for a fix |
| `GET` | `/relay-selection` | Verified relay-vehicle selection at a stop/POI |
| `POST` | `/auth/signup` | Create an account |
| `POST` | `/auth/login` | Sign in and obtain a JWT |
| `GET` | `/auth/me` | Inspect the current authenticated user |

---

## Repository Layout

```text
docker-compose.yml        PostgreSQL 17 + PostGIS 3.5 + Adminer
start-all.bat             Windows one-click local stack launcher (DB + API + ngrok)
package.json              Node scripts for API, offline export, and pipeline tools
.env.example              Environment template

api/
  src/                    Fastify server, ETA, journey, arrivals, auth, crowdsource, GNSS proof
  README.md               API documentation

app/
  lib/                    Flutter application (Board, Plan, Saved, You, Ride, Route, Offline pack)
  assets/                 Bundled Barlow fonts and generated offline SQLite pack
  test/                   Flutter unit and widget tests

db/                       PostgreSQL/PostGIS schemas, loaders, and travel-time SQL scripts
tools/                    Offline DB exporter, realtime loader, map-matcher, passenger simulator
scripts/                  Pipeline runner scripts (process-week.sh, run-full-pipeline.sh)
```
