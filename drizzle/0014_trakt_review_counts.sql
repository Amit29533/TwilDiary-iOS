-- Incremental review aggregates avoid rescanning every proposal after each apply.
-- Backfill covers already-active reviews; triggers share the change transaction.
CREATE TABLE trakt_sync_change_counts (
  run_id TEXT NOT NULL REFERENCES trakt_sync_runs(id) ON DELETE CASCADE,
  state TEXT NOT NULL,
  review INTEGER NOT NULL,
  direction TEXT NOT NULL,
  amount INTEGER NOT NULL DEFAULT 0 CHECK(amount >= 0),
  PRIMARY KEY(run_id,state,review,direction)
);
--> statement-breakpoint
INSERT INTO trakt_sync_change_counts(run_id,state,review,direction,amount)
SELECT run_id,state,review,direction,COUNT(*) FROM trakt_sync_changes
GROUP BY run_id,state,review,direction;
--> statement-breakpoint
CREATE TRIGGER trakt_change_count_insert AFTER INSERT ON trakt_sync_changes BEGIN
  INSERT INTO trakt_sync_change_counts(run_id,state,review,direction,amount)
  VALUES(NEW.run_id,NEW.state,NEW.review,NEW.direction,1)
  ON CONFLICT(run_id,state,review,direction) DO UPDATE SET amount=amount+1;
END;
--> statement-breakpoint
CREATE TRIGGER trakt_change_count_delete AFTER DELETE ON trakt_sync_changes BEGIN
  UPDATE trakt_sync_change_counts SET amount=amount-1
  WHERE run_id=OLD.run_id AND state=OLD.state AND review=OLD.review AND direction=OLD.direction;
END;
--> statement-breakpoint
CREATE TRIGGER trakt_change_count_update AFTER UPDATE OF run_id,state,review,direction ON trakt_sync_changes
WHEN OLD.run_id<>NEW.run_id OR OLD.state<>NEW.state OR OLD.review<>NEW.review OR OLD.direction<>NEW.direction BEGIN
  UPDATE trakt_sync_change_counts SET amount=amount-1
  WHERE run_id=OLD.run_id AND state=OLD.state AND review=OLD.review AND direction=OLD.direction;
  INSERT INTO trakt_sync_change_counts(run_id,state,review,direction,amount)
  VALUES(NEW.run_id,NEW.state,NEW.review,NEW.direction,1)
  ON CONFLICT(run_id,state,review,direction) DO UPDATE SET amount=amount+1;
END;
--> statement-breakpoint
-- Same dependency order as applySyncChange's existing reviewed operation.
CREATE INDEX trakt_changes_ready_pick ON trakt_sync_changes(
  run_id,
  CASE WHEN kind='history' AND direction='pull' THEN 0 WHEN direction='link' THEN 1 WHEN kind='rating' THEN 2 ELSE 3 END,
  id
) WHERE state='pending' AND review=0;

--> statement-breakpoint
CREATE INDEX trakt_remote_plan_order ON trakt_remote_items(run_id,id) WHERE kind!='activities';
