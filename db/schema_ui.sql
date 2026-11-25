-- Read-side indexes for the new arrivals/replay endpoints.
--
-- The arrivals endpoint asks "what did each bus on these routes pass in the
-- twenty minutes around this recorded time?" The existing indexes cover a
-- whole day or a vehicle, which would make that query scan far more rows
-- than it needs. This composite index matches the query exactly:
-- day first, then the routes at the stop, then the time window.
--
-- Safe to run more than once.

CREATE INDEX IF NOT EXISTS idx_osp_day_route_time
  ON observed_stop_passage (day, route_id, passage_time);

ANALYZE observed_stop_passage;
