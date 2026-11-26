-- Unified scraper progress / deduplication ledger.
--
-- Problem this solves:
--   * checkpoints were written centrally, but known post IDs and "progress.json"
--     state were local files only, so a fresh GitHub runner (or a cancelled run)
--     lost them;
--   * scraper_get_known_post_ids only covered viral-mms / supjav / myanmar, so
--     OnlyFans and Voyeur House sources could never restore their dedupe cache.
--
-- The ledger is additive: existing per-category tables remain the historical
-- source of IDs, and the new table stores IDs that were seen but never stored
-- (dead links, photo sets, blocked detail pages).

CREATE SCHEMA IF NOT EXISTS scraper;

CREATE TABLE IF NOT EXISTS scraper.known_post_ids (
    site          TEXT        NOT NULL,
    post_id       TEXT        NOT NULL,
    status        TEXT        NOT NULL DEFAULT 'seen',
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now()),
    PRIMARY KEY (site, post_id)
);

CREATE INDEX IF NOT EXISTS known_post_ids_site_last_seen_idx
    ON scraper.known_post_ids (site, last_seen_at DESC);

GRANT USAGE ON SCHEMA scraper TO anon, authenticated, service_role;
GRANT ALL ON scraper.known_post_ids TO anon, authenticated, service_role;

-- Persist a batch of known IDs for one site. Idempotent, chunk-friendly.
CREATE OR REPLACE FUNCTION public.scraper_add_known_post_ids(
    p_site   TEXT,
    p_ids    JSONB,
    p_status TEXT DEFAULT 'seen'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $func$
DECLARE
    v_site   TEXT;
    v_status TEXT;
    v_ids    TEXT[];
BEGIN
    v_site := lower(btrim(COALESCE(p_site, '')));
    v_status := lower(btrim(COALESCE(p_status, 'seen')));
    IF v_site = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing site');
    END IF;

    SELECT COALESCE(array_agg(DISTINCT btrim(x)), '{}'::TEXT[])
      INTO v_ids
      FROM jsonb_array_elements_text(COALESCE(p_ids, '[]'::JSONB)) AS x
     WHERE btrim(x) <> '';

    INSERT INTO scraper.known_post_ids (site, post_id, status, last_seen_at)
    SELECT v_site, u, v_status, timezone('utc'::text, now())
      FROM unnest(v_ids) AS u
    ON CONFLICT (site, post_id) DO UPDATE
       SET status = EXCLUDED.status,
           last_seen_at = timezone('utc'::text, now());

    RETURN jsonb_build_object('success', true, 'count', cardinality(v_ids));
END;
$func$;

-- Restore all known IDs for a site: historical rows from the isolated table
-- plus every ID in the central ledger (including "seen but not stored" IDs).
CREATE OR REPLACE FUNCTION public.scraper_get_known_post_ids(
    p_site  TEXT,
    p_limit INT DEFAULT 100000
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $func$
DECLARE
    v_site    TEXT := lower(btrim(COALESCE(p_site, '')));
    v_limit   INT := GREATEST(1, LEAST(COALESCE(p_limit, 100000), 200000));
    v_table   TEXT;
    v_filter  TEXT := '';
    v_legacy  JSONB := '[]'::JSONB;
    v_ledger  JSONB := '[]'::JSONB;
    v_result  JSONB;
BEGIN
    v_table := CASE v_site
        WHEN 'viral-mms'              THEN 'videos'
        WHEN 'mmsvibex'               THEN 'videos'
        WHEN 'japanese'               THEN 'japanese_videos'
        WHEN 'supjav'                 THEN 'japanese_videos'
        WHEN 'jav'                    THEN 'japanese_videos'
        WHEN 'myanmar'                THEN 'myanmar_videos'
        WHEN 'buumal'                 THEN 'myanmar_videos'
        WHEN 'influencersgonewild'    THEN 'onlyfans_videos'
        WHEN 'sheeshfans'             THEN 'onlyfans_videos'
        WHEN 'voyeurhouseorg'         THEN 'voyeurhouse_videos'
        WHEN 'hotscopesvoyeurhouse'   THEN 'hotscopesvoyeurhouse_videos'
        WHEN 'reallifecamto'          THEN 'reallifecamto_videos'
        WHEN 'hotscopesspygasm'       THEN 'hotscopesspygasm_videos'
        WHEN 'hotscopesreallifecam'   THEN 'hotscopesreallifecam_videos'
        ELSE NULL
    END;

    IF v_table IS NOT NULL AND to_regclass('scraper.' || v_table) IS NOT NULL THEN
        IF v_site IN ('influencersgonewild', 'sheeshfans') THEN
            v_filter := format('AND source_site = %L', v_site);
        END IF;
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(source_post_id), ''[]''::JSONB) '
            'FROM (SELECT source_post_id FROM scraper.%I '
            'WHERE source_post_id IS NOT NULL %s '
            'ORDER BY scraped_at DESC LIMIT $1) t',
            v_table, v_filter
        ) INTO v_legacy USING v_limit;
    END IF;

    SELECT COALESCE(jsonb_agg(post_id), '[]'::JSONB)
      INTO v_ledger
      FROM (
          SELECT post_id
            FROM scraper.known_post_ids
           WHERE site = v_site
           ORDER BY last_seen_at DESC
           LIMIT v_limit
      ) s;

    SELECT COALESCE(jsonb_agg(DISTINCT x), '[]'::JSONB)
      INTO v_result
      FROM jsonb_array_elements_text(v_legacy || v_ledger) AS x;

    RETURN COALESCE(v_result, '[]'::JSONB);
END;
$func$;

GRANT EXECUTE ON FUNCTION public.scraper_add_known_post_ids(TEXT, JSONB, TEXT)
    TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scraper_get_known_post_ids(TEXT, INT)
    TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
