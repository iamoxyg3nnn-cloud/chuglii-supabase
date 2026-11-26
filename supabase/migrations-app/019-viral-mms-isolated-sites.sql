-- ============================================================================
-- MIGRATION: Isolated Viral MMS per-site tables and RPCs
-- Sites: spicymms, desi49, mydesi, indianbfclips
-- Purpose: Each website owns an isolated database table + RPC family
--   (scraper.<site>_videos, public.scraper_*_<site>_videos), while existing
--   scraper.videos (mmsvibex) stays completely untouched.
-- ============================================================================

DO $$
DECLARE
    site_key text;
    table_key text;
BEGIN
    FOREACH site_key IN ARRAY ARRAY['spicymms', 'desi49', 'mydesi', 'indianbfclips'] LOOP
        table_key := site_key || '_videos';

        EXECUTE format($ddl$
            CREATE TABLE IF NOT EXISTS scraper.%I (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                source_site TEXT NOT NULL DEFAULT %L CHECK (source_site = %L),
                source_post_id TEXT NOT NULL,
                title TEXT NOT NULL,
                slug TEXT,
                detail_url TEXT NOT NULL,
                full_video_url TEXT,
                video_mime_type TEXT DEFAULT 'video/mp4',
                trailer_preview_url TEXT,
                thumbnail_url TEXT,
                clean_thumbnail_url TEXT,
                duration_seconds INTEGER,
                duration_formatted VARCHAR(32),
                views_count BIGINT DEFAULT 0,
                views_raw VARCHAR(64) DEFAULT '0',
                rating_score NUMERIC(5,2) DEFAULT 0.0,
                rating_raw VARCHAR(32) DEFAULT '0%%',
                categories TEXT[] DEFAULT '{viral-mms}',
                tags TEXT[] DEFAULT '{}',
                actors TEXT[] DEFAULT '{}',
                status TEXT DEFAULT 'active',
                published_at TIMESTAMPTZ,
                scraped_at TIMESTAMPTZ DEFAULT now(),
                updated_at TIMESTAMPTZ DEFAULT now(),
                raw_payload JSONB DEFAULT '{}'::jsonb,
                CONSTRAINT %I UNIQUE (source_site, source_post_id)
            )
        $ddl$, table_key, site_key, site_key, 'uq_' || table_key);

        EXECUTE format('ALTER TABLE scraper.%I ENABLE ROW LEVEL SECURITY', table_key);
        EXECUTE format('DROP POLICY IF EXISTS %I ON scraper.%I', 'service_role_all_' || table_key, table_key);
        EXECUTE format('CREATE POLICY %I ON scraper.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', 'service_role_all_' || table_key, table_key);
        EXECUTE format('DROP POLICY IF EXISTS %I ON scraper.%I', 'anon_select_' || table_key, table_key);
        EXECUTE format('CREATE POLICY %I ON scraper.%I FOR SELECT TO anon, authenticated USING (status = ''active'')', 'anon_select_' || table_key, table_key);

        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I (source_site, source_post_id)', 'idx_' || table_key || '_source', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I (scraped_at DESC)', 'idx_' || table_key || '_scraped', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I (published_at DESC NULLS LAST)', 'idx_' || table_key || '_published', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I (views_count DESC)', 'idx_' || table_key || '_views', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I (duration_seconds DESC NULLS LAST)', 'idx_' || table_key || '_duration', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I USING gin(tags)', 'idx_' || table_key || '_tags', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I USING gin(categories)', 'idx_' || table_key || '_categories', table_key);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON scraper.%I USING gin(actors)', 'idx_' || table_key || '_actors', table_key);
    END LOOP;
END;
$$;

-- Shared private helpers pinned per site by public wrappers below.
CREATE OR REPLACE FUNCTION public.scraper_upsert_viral_mms_site_videos(p_site text, items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $$
DECLARE
    table_key text;
    affected_count integer;
BEGIN
    IF p_site NOT IN ('spicymms', 'desi49', 'mydesi', 'indianbfclips') THEN
        RAISE EXCEPTION 'Unknown Viral MMS source: %', p_site;
    END IF;
    table_key := p_site || '_videos';

    EXECUTE format($upsert$
        WITH raw_items AS (
            SELECT DISTINCT ON (NULLIF(btrim(x->>'source_post_id'), ''))
                %L AS source_site,
                NULLIF(btrim(x->>'source_post_id'), '') AS source_post_id,
                COALESCE(NULLIF(btrim(x->>'title'), ''), 'Viral MMS Video') AS title,
                NULLIF(btrim(x->>'slug'), '') AS slug,
                COALESCE(NULLIF(btrim(x->>'detail_url'), ''), '') AS detail_url,
                NULLIF(btrim(x->>'full_video_url'), '') AS full_video_url,
                COALESCE(NULLIF(btrim(x->>'video_mime_type'), ''), 'video/mp4') AS video_mime_type,
                NULLIF(btrim(x->>'trailer_preview_url'), '') AS trailer_preview_url,
                NULLIF(btrim(x->>'thumbnail_url'), '') AS thumbnail_url,
                NULLIF(btrim(x->>'clean_thumbnail_url'), '') AS clean_thumbnail_url,
                (x->>'duration_seconds')::integer AS duration_seconds,
                NULLIF(btrim(x->>'duration_formatted'), '')::varchar AS duration_formatted,
                COALESCE((x->>'views_count')::bigint, 0) AS views_count,
                COALESCE(NULLIF(btrim(x->>'views_raw'), ''), '0')::varchar AS views_raw,
                COALESCE((x->>'rating_score')::numeric(5,2), 0.0) AS rating_score,
                COALESCE(NULLIF(btrim(x->>'rating_raw'), ''), '0%%')::varchar AS rating_raw,
                COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'categories', '["viral-mms"]'::jsonb))), ARRAY['viral-mms']::text[]) AS categories,
                COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'tags', '[]'::jsonb))), ARRAY[]::text[]) AS tags,
                COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(x->'actors', '[]'::jsonb))), ARRAY[]::text[]) AS actors,
                COALESCE(NULLIF(btrim(x->>'status'), ''), 'active') AS status,
                CASE WHEN NULLIF(btrim(x->>'published_at'), '') IS NOT NULL
                     THEN (x->>'published_at')::timestamptz ELSE NULL END AS published_at,
                COALESCE(x->'raw_payload', '{}'::jsonb) AS raw_payload
            FROM jsonb_array_elements($1) AS x
            WHERE NULLIF(btrim(x->>'source_post_id'), '') IS NOT NULL
              AND NULLIF(btrim(x->>'full_video_url'), '') IS NOT NULL
        )
        INSERT INTO scraper.%I (
            source_site, source_post_id, title, slug, detail_url,
            full_video_url, video_mime_type, trailer_preview_url,
            thumbnail_url, clean_thumbnail_url, duration_seconds, duration_formatted,
            views_count, views_raw, rating_score, rating_raw,
            categories, tags, actors, status, published_at, raw_payload, updated_at
        )
        SELECT
            source_site, source_post_id, title, slug, detail_url,
            full_video_url, video_mime_type, trailer_preview_url,
            thumbnail_url, clean_thumbnail_url, duration_seconds, duration_formatted,
            views_count, views_raw, rating_score, rating_raw,
            categories, tags, actors, status, published_at, raw_payload, now()
        FROM raw_items
        ON CONFLICT (source_site, source_post_id) DO UPDATE SET
            title = EXCLUDED.title,
            slug = COALESCE(EXCLUDED.slug, scraper.%I.slug),
            detail_url = EXCLUDED.detail_url,
            full_video_url = EXCLUDED.full_video_url,
            video_mime_type = EXCLUDED.video_mime_type,
            trailer_preview_url = COALESCE(EXCLUDED.trailer_preview_url, scraper.%I.trailer_preview_url),
            thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, scraper.%I.thumbnail_url),
            clean_thumbnail_url = COALESCE(EXCLUDED.clean_thumbnail_url, scraper.%I.clean_thumbnail_url),
            duration_seconds = COALESCE(EXCLUDED.duration_seconds, scraper.%I.duration_seconds),
            duration_formatted = COALESCE(EXCLUDED.duration_formatted, scraper.%I.duration_formatted),
            views_count = GREATEST(EXCLUDED.views_count, scraper.%I.views_count),
            views_raw = COALESCE(EXCLUDED.views_raw, scraper.%I.views_raw),
            rating_score = COALESCE(EXCLUDED.rating_score, scraper.%I.rating_score),
            rating_raw = COALESCE(EXCLUDED.rating_raw, scraper.%I.rating_raw),
            categories = EXCLUDED.categories,
            tags = EXCLUDED.tags,
            actors = EXCLUDED.actors,
            status = EXCLUDED.status,
            published_at = COALESCE(EXCLUDED.published_at, scraper.%I.published_at),
            raw_payload = EXCLUDED.raw_payload,
            updated_at = now()
    $upsert$, p_site, table_key,
        table_key, table_key, table_key, table_key, table_key,
        table_key, table_key, table_key, table_key, table_key, table_key
    ) USING items;

    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN jsonb_build_object('success', true, 'count', affected_count);
END;
$$;

REVOKE ALL ON FUNCTION public.scraper_upsert_viral_mms_site_videos(text, jsonb) FROM PUBLIC, anon, authenticated, service_role;

DO $$
DECLARE
    site_key text;
    table_key text;
BEGIN
    FOREACH site_key IN ARRAY ARRAY['spicymms', 'desi49', 'mydesi', 'indianbfclips'] LOOP
        table_key := site_key || '_videos';

        EXECUTE format($upsert_fn$
            CREATE OR REPLACE FUNCTION public.scraper_upsert_%1$s_videos(items jsonb)
            RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = scraper, public
            AS $body$ SELECT public.scraper_upsert_viral_mms_site_videos(%2$L, items) $body$;
        $upsert_fn$, site_key, site_key);

        EXECUTE format($get_fn$
            CREATE OR REPLACE FUNCTION public.scraper_get_%1$s_videos(
                p_source_site text DEFAULT NULL,
                p_tag text DEFAULT NULL,
                p_category text DEFAULT NULL,
                p_search text DEFAULT NULL,
                p_sort text DEFAULT 'newest',
                p_limit int DEFAULT 24,
                p_offset int DEFAULT 0
            )
            RETURNS SETOF scraper.%2$I
            LANGUAGE sql
            STABLE
            SECURITY DEFINER
            SET search_path = scraper, public
            AS $body$
                SELECT * FROM scraper.%2$I
                WHERE (p_source_site IS NULL OR source_site = p_source_site)
                  AND (
                      p_category IS NULL
                      OR lower(trim(p_category)) IN ('all', 'viral-mms')
                      OR lower(trim(p_category)) = ANY(categories)
                      OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
                  )
                  AND (
                      p_tag IS NULL
                      OR lower(trim(p_tag)) = 'all'
                      OR lower(trim(p_tag)) = ANY(tags)
                      OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
                      OR lower(trim(p_tag)) = ANY(categories)
                  )
                  AND (
                      p_search IS NULL
                      OR trim(p_search) = ''
                      OR (
                          SELECT bool_and(
                            lower(title) LIKE '%%' || word || '%%'
                            OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%%' || word || '%%'
                            OR lower(array_to_string(tags, ' ')) LIKE '%%' || word || '%%'
                            OR lower(array_to_string(categories, ' ')) LIKE '%%' || word || '%%'
                          )
                          FROM unnest(string_to_array(lower(trim(p_search)), ' ')) AS word
                          WHERE length(word) > 0
                      )
                  )
                  AND status = 'active'
                  AND full_video_url IS NOT NULL AND full_video_url <> ''
                ORDER BY
                  CASE WHEN p_sort = 'newest' THEN scraped_at END DESC NULLS LAST,
                  CASE WHEN p_sort = 'views' THEN views_count END DESC NULLS LAST,
                  CASE WHEN p_sort = 'rating' THEN rating_score END DESC NULLS LAST,
                  CASE WHEN p_sort = 'longest' THEN duration_seconds END DESC NULLS LAST,
                  CASE WHEN p_sort = 'oldest' THEN published_at END ASC NULLS LAST,
                  published_at DESC NULLS LAST,
                  scraped_at DESC,
                  id DESC
                LIMIT p_limit OFFSET p_offset;
            $body$;
        $get_fn$, site_key, table_key);

        EXECUTE format($count_fn$
            CREATE OR REPLACE FUNCTION public.scraper_count_%1$s_videos(
                p_source_site text DEFAULT NULL,
                p_tag text DEFAULT NULL,
                p_category text DEFAULT NULL,
                p_search text DEFAULT NULL
            )
            RETURNS bigint
            LANGUAGE sql
            STABLE
            SECURITY DEFINER
            SET search_path = scraper, public
            AS $body$
                SELECT count(*) FROM scraper.%2$I
                WHERE (p_source_site IS NULL OR source_site = p_source_site)
                  AND (
                      p_category IS NULL
                      OR lower(trim(p_category)) IN ('all', 'viral-mms')
                      OR lower(trim(p_category)) = ANY(categories)
                      OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
                  )
                  AND (
                      p_tag IS NULL
                      OR lower(trim(p_tag)) = 'all'
                      OR lower(trim(p_tag)) = ANY(tags)
                      OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
                      OR lower(trim(p_tag)) = ANY(categories)
                  )
                  AND (
                      p_search IS NULL
                      OR trim(p_search) = ''
                      OR (
                          SELECT bool_and(
                            lower(title) LIKE '%%' || word || '%%'
                            OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%%' || word || '%%'
                            OR lower(array_to_string(tags, ' ')) LIKE '%%' || word || '%%'
                            OR lower(array_to_string(categories, ' ')) LIKE '%%' || word || '%%'
                          )
                          FROM unnest(string_to_array(lower(trim(p_search)), ' ')) AS word
                          WHERE length(word) > 0
                      )
                  )
                  AND status = 'active'
                  AND full_video_url IS NOT NULL AND full_video_url <> '';
            $body$;
        $count_fn$, site_key, table_key);

        EXECUTE format($detail_fn$
            CREATE OR REPLACE FUNCTION public.scraper_get_%1$s_video_by_id(p_id text)
            RETURNS SETOF scraper.%2$I
            LANGUAGE sql
            STABLE
            SECURITY DEFINER
            SET search_path = scraper, public
            AS $body$
                SELECT * FROM scraper.%2$I
                WHERE id::text = p_id
                  AND status = 'active'
                  AND full_video_url IS NOT NULL AND full_video_url <> ''
                LIMIT 1;
            $body$;
        $detail_fn$, site_key, table_key);

        EXECUTE format('REVOKE ALL ON FUNCTION public.scraper_upsert_%s_videos(jsonb) FROM PUBLIC, anon, authenticated', site_key);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.scraper_upsert_%s_videos(jsonb) TO service_role', site_key);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.scraper_get_%s_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role', site_key);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.scraper_count_%s_videos(text, text, text, text) TO anon, authenticated, service_role', site_key);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.scraper_get_%s_video_by_id(text) TO anon, authenticated, service_role', site_key);
    END LOOP;
END;
$$;

NOTIFY pgrst, 'reload schema';
