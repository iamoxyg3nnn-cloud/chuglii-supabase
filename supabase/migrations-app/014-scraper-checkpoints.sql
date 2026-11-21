CREATE SCHEMA IF NOT EXISTS scraper;

CREATE TABLE IF NOT EXISTS scraper.checkpoints (
    key TEXT PRIMARY KEY,
    state JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc'::text, now())
);

GRANT USAGE ON SCHEMA scraper TO anon, authenticated, service_role;
GRANT ALL ON scraper.checkpoints TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.scraper_get_checkpoint(p_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
    v_state JSONB;
BEGIN
    SELECT state INTO v_state
    FROM scraper.checkpoints
    WHERE key = p_key;
    
    RETURN COALESCE(v_state, '{}'::jsonb);
END;
$func$;

CREATE OR REPLACE FUNCTION public.scraper_set_checkpoint(p_key TEXT, p_state JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
BEGIN
    INSERT INTO scraper.checkpoints (key, state, updated_at)
    VALUES (p_key, p_state, timezone('utc'::text, now()))
    ON CONFLICT (key) DO UPDATE
    SET state = EXCLUDED.state,
        updated_at = timezone('utc'::text, now());
        
    RETURN jsonb_build_object('success', true);
END;
$func$;

CREATE OR REPLACE FUNCTION public.scraper_get_known_post_ids(p_site TEXT, p_limit INT DEFAULT 25000)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
    v_result JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(source_post_id), '[]'::jsonb)
    INTO v_result
    FROM (
        SELECT (metadata->>'post_id')::TEXT AS source_post_id
        FROM recordings
        WHERE (metadata->>'source_site' = p_site OR tags ? p_site)
          AND metadata->>'post_id' IS NOT NULL
        ORDER BY created_at DESC
        LIMIT p_limit
    ) sub;
    
    RETURN v_result;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.scraper_get_checkpoint(TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scraper_set_checkpoint(TEXT, JSONB) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scraper_get_known_post_ids(TEXT, INT) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
