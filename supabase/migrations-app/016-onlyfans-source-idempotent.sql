-- Make the per-source OnlyFans insert RPCs safe to retry.
--
-- The current helper uses a plain INSERT.  If the canonical upsert fails but
-- the per-source sync succeeds, the ID is deliberately left unmarked for
-- retry; the next cycle would then insert the same row a second time.  Adding
-- a NOT EXISTS guard makes the RPC idempotent without requiring a disruptive
-- UNIQUE constraint on tables that already contain legacy duplicates.

CREATE OR REPLACE FUNCTION public.scraper_insert_onlyfans_source_videos(p_site text, items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $$
DECLARE
    table_key text;
    inserted_count integer;
BEGIN
    IF p_site NOT IN ('internetchicks', 'influencersgonewild', 'sheeshfans') THEN
        RAISE EXCEPTION 'Unknown OnlyFans source: %', p_site;
    END IF;
    table_key := p_site || '_videos';

    EXECUTE format($insert$
        INSERT INTO scraper.%I (
            source_site, source_post_id, title, slug, detail_url, full_video_url,
            video_mime_type, trailer_preview_url, thumbnail_url, clean_thumbnail_url,
            quality_label, quality_score, duration_seconds, duration_formatted,
            views_count, views_raw, rating_score, rating_raw, categories, tags,
            actors, status, published_at, raw_payload
        )
        SELECT
            $2, x.source_post_id, COALESCE(x.title, ''), x.slug, COALESCE(x.detail_url, ''),
            x.full_video_url, COALESCE(x.video_mime_type, 'embed/iframe'), x.trailer_preview_url,
            x.thumbnail_url, x.clean_thumbnail_url, COALESCE(x.quality_label, '1080p Full HD'),
            COALESCE(x.quality_score, 1080), COALESCE(x.duration_seconds, 600),
            COALESCE(x.duration_formatted, '10:00'), COALESCE(x.views_count, 0),
            COALESCE(x.views_raw, '0'), COALESCE(x.rating_score, 95.0),
            COALESCE(x.rating_raw, '95%%'),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(x.categories)), ARRAY['onlyfans']::text[]),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(x.tags)), ARRAY[]::text[]),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(x.actors)), ARRAY[]::text[]),
            COALESCE(x.status, 'active'), x.published_at, COALESCE(x.raw_payload, '{}'::jsonb)
        FROM jsonb_to_recordset($1) AS x(
            source_post_id text, title text, slug text, detail_url text, full_video_url text,
            video_mime_type text, trailer_preview_url text, thumbnail_url text,
            clean_thumbnail_url text, quality_label text, quality_score integer,
            duration_seconds integer, duration_formatted text, views_count bigint,
            views_raw text, rating_score numeric, rating_raw text, categories jsonb,
            tags jsonb, actors jsonb, status text, published_at timestamptz, raw_payload jsonb
        )
        WHERE x.source_post_id IS NOT NULL AND btrim(x.source_post_id) <> ''
          AND NOT EXISTS (
              SELECT 1 FROM scraper.%I existing
              WHERE existing.source_site = $2
                AND existing.source_post_id = x.source_post_id
          )
    $insert$, table_key, table_key) USING items, p_site;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN jsonb_build_object(
        'success', true,
        'inserted', inserted_count,
        'count', inserted_count,
        'skipped_existing', greatest(coalesce(jsonb_array_length(items), 0) - inserted_count, 0)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.scraper_insert_onlyfans_source_videos(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scraper_insert_onlyfans_source_videos(text, jsonb) TO service_role;

NOTIFY pgrst, 'reload schema';
