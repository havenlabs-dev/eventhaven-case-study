-- Excerpt from EventHaven (private repo): supabase/migrations/028_atomic_resource_claims.sql
-- Event-specific examples genericized and the one-time backfill (step 5) removed; schema and functions unchanged.

-- Atomic claims for limited resources (shirt sizes today; event capacity and
-- ticket tiers next).
--
-- Why this exists: every "limited thing" in EventHaven was enforced with a
-- read-then-write — count the rows, compare to the cap, insert later. Two
-- registrants passing the same check both get in. For paid events the gap is
-- not milliseconds but minutes, because the check runs in createStripeCheckout
-- and the insert happens in the Stripe webhook after the card is entered.
--
-- The fix is a claim ledger plus one function that counts and inserts while
-- holding a lock, so the check and the write cannot be separated.

-- 1. Per-option limits on a custom field: {"S":6,"M":13,"L":15,"XL":11,"2XL":5}
--    quantity_limit (migration 017) keeps working and now means "cap across all
--    options" — e.g. a hard stop at 50 shirts total.
ALTER TABLE event_fields ADD COLUMN IF NOT EXISTS option_limits JSONB DEFAULT NULL;

-- 2. The claim ledger.
--
--    resource_id is NOT NULL by design: event_capacity uses the event's own id
--    rather than NULL, so the UNIQUE constraint below behaves normally (NULLs
--    would compare as distinct and let duplicates through).
--
--    One row per claimed unit. For a shirt field, the per-size count and the
--    across-all-sizes total are both derived from these same rows, so they can
--    never disagree with each other.
CREATE TABLE IF NOT EXISTS resource_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  resource_type TEXT NOT NULL CHECK (resource_type IN ('field_option', 'event_capacity', 'ticket_tier')),
  resource_id UUID NOT NULL,
  resource_key TEXT NOT NULL DEFAULT '',
  registration_id UUID NOT NULL REFERENCES registrations(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- A registration holds at most one claim per resource. This is also the
  -- idempotency guard for Stripe webhook replays.
  CONSTRAINT resource_claims_one_per_registration UNIQUE (resource_type, resource_id, registration_id)
);

CREATE INDEX IF NOT EXISTS resource_claims_resource_idx
  ON resource_claims (resource_type, resource_id);
CREATE INDEX IF NOT EXISTS resource_claims_resource_key_idx
  ON resource_claims (resource_type, resource_id, resource_key);
CREATE INDEX IF NOT EXISTS resource_claims_registration_idx
  ON resource_claims (registration_id);
CREATE INDEX IF NOT EXISTS resource_claims_event_idx
  ON resource_claims (event_id);

ALTER TABLE resource_claims ENABLE ROW LEVEL SECURITY;

-- Public registration reads go through the service role (see migration 022);
-- this policy is only so signed-in org members can read their own claims.
DROP POLICY IF EXISTS "org members can read resource claims" ON resource_claims;
CREATE POLICY "org members can read resource claims"
  ON resource_claims FOR SELECT
  USING (
    event_id IN (
      SELECT e.id FROM events e
      WHERE e.org_id IN (SELECT org_id FROM org_members WHERE user_id = auth.uid())
    )
  );

-- 3. The atomic claim.
--
--    p_key_limit   caps this one key   (a single shirt size; NULL = uncapped)
--    p_group_limit caps all keys       (50 shirts total;      NULL = uncapped)
--
--    Limits are passed in rather than read from event_fields/events/ticket_tiers
--    so this function stays generic and does not couple to three schemas.
--
--    Returns: 'ok' | 'already_claimed' | 'key_sold_out' | 'group_sold_out'
CREATE OR REPLACE FUNCTION claim_resource(
  p_event_id UUID,
  p_resource_type TEXT,
  p_resource_id UUID,
  p_resource_key TEXT,
  p_key_limit INT,
  p_group_limit INT,
  p_registration_id UUID
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key_count INT;
  v_group_count INT;
BEGIN
  -- Serialize every claim against this one resource. The lock is transaction
  -- scoped, so it releases on commit or rollback with no cleanup path to get
  -- wrong. Claims against different resources (a different field, a different
  -- event) take different lock keys and never block each other, so the two
  -- concurrent-Large submissions contend while an S and an XL do not.
  PERFORM pg_advisory_xact_lock(hashtext(p_resource_type), hashtext(p_resource_id::text));

  -- Replay safety: a redelivered Stripe webhook must not consume a second unit.
  IF EXISTS (
    SELECT 1 FROM resource_claims
    WHERE resource_type = p_resource_type
      AND resource_id = p_resource_id
      AND registration_id = p_registration_id
  ) THEN
    RETURN 'already_claimed';
  END IF;

  IF p_group_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_group_count
    FROM resource_claims
    WHERE resource_type = p_resource_type AND resource_id = p_resource_id;

    IF v_group_count >= p_group_limit THEN
      RETURN 'group_sold_out';
    END IF;
  END IF;

  IF p_key_limit IS NOT NULL THEN
    SELECT COUNT(*) INTO v_key_count
    FROM resource_claims
    WHERE resource_type = p_resource_type
      AND resource_id = p_resource_id
      AND resource_key = p_resource_key;

    IF v_key_count >= p_key_limit THEN
      RETURN 'key_sold_out';
    END IF;
  END IF;

  INSERT INTO resource_claims (event_id, resource_type, resource_id, resource_key, registration_id)
  VALUES (p_event_id, p_resource_type, p_resource_id, p_resource_key, p_registration_id);

  RETURN 'ok';
END;
$$;

-- 4. Release — a cancelled registration puts its shirt back in the pool.
CREATE OR REPLACE FUNCTION release_resource_claims(p_registration_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INT;
BEGIN
  DELETE FROM resource_claims WHERE registration_id = p_registration_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION claim_resource(UUID, TEXT, UUID, TEXT, INT, INT, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION release_resource_claims(UUID) FROM PUBLIC, anon, authenticated;

