-- ============================================================================
-- DEDUPLICATION AND TIEBREAKER MIGRATION
-- ============================================================================

-- 1. DELETE EXACT CONTENT DUPLICATES FROM scraper.videos
WITH ranked_videos AS (
    SELECT 
        id,
        full_video_url,
        duration_seconds,
        ROW_NUMBER() OVER (
            PARTITION BY full_video_url
            ORDER BY 
                views_count DESC,
                (CASE WHEN full_video_url IS NOT NULL AND full_video_url <> '' THEN 1 ELSE 0 END) DESC,
                scraped_at ASC,
                id ASC
        ) as rank_by_video_url,
        ROW_NUMBER() OVER (
            PARTITION BY lower(trim(title)), duration_seconds
            ORDER BY 
                (CASE WHEN full_video_url IS NOT NULL AND full_video_url <> '' THEN 1 ELSE 0 END) DESC,
                views_count DESC,
                scraped_at ASC,
                id ASC
        ) as rank_by_title_dur
    FROM scraper.videos
),
to_delete AS (
    SELECT DISTINCT id
    FROM ranked_videos
    WHERE (full_video_url IS NOT NULL AND trim(full_video_url) <> '' AND rank_by_video_url > 1)
       OR (duration_seconds IS NOT NULL AND duration_seconds > 0 AND rank_by_title_dur > 1)
)
DELETE FROM scraper.videos WHERE id IN (SELECT id FROM to_delete);

-- 2. ENRICH MULTI-PART TITLES FROM SLUGS (e.g. 'Desi Couple Sex' -> 'Desi Couple Sex - Part 2')
UPDATE scraper.videos
SET title = 
    CASE 
        WHEN slug ~* '-part-?([0-9]+)$' AND title !~* 'part[ -]?[0-9]+'
            THEN title || ' - Part ' || (regexp_match(slug, '-part-?([0-9]+)$', 'i'))[1]
        WHEN slug ~* '-([0-9]{1,2})$' AND title !~* 'part[ -]?[0-9]+' AND title !~* ('[ -]' || (regexp_match(slug, '-([0-9]{1,2})$'))[1] || '$')
            THEN title || ' - Part ' || (regexp_match(slug, '-([0-9]{1,2})$'))[1]
        ELSE title
    END
WHERE (
    (slug ~* '-part-?([0-9]+)$' AND title !~* 'part[ -]?[0-9]+')
    OR (slug ~* '-([0-9]{1,2})$' AND title !~* 'part[ -]?[0-9]+' AND title !~* ('[ -]' || (regexp_match(slug, '-([0-9]{1,2})$'))[1] || '$'))
);

-- 3. UPGRADE scraper_upsert_videos WITH INGESTION-TIME CONTENT DEDUPLICATION
CREATE OR REPLACE FUNCTION public.scraper_upsert_videos(items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = scraper, public
AS $$
DECLARE
    v jsonb;
    inserted_count int := 0;
    existing_id uuid;
BEGIN
    FOR v IN SELECT * FROM jsonb_array_elements(items)
    LOOP
        existing_id := NULL;

        -- A. Check if exact full_video_url exists
        IF (v->>'full_video_url') IS NOT NULL AND trim(v->>'full_video_url') <> '' THEN
            SELECT id INTO existing_id
            FROM scraper.videos
            WHERE full_video_url = (v->>'full_video_url')
            LIMIT 1;
        END IF;

        -- B. Check if exact title + duration exists
        IF existing_id IS NULL AND (v->>'duration_seconds')::int > 0 THEN
            SELECT id INTO existing_id
            FROM scraper.videos
            WHERE lower(trim(title)) = lower(trim(v->>'title'))
              AND duration_seconds = (v->>'duration_seconds')::int
            LIMIT 1;
        END IF;

        -- If existing duplicate found, update metrics and skip duplicate row insertion
        IF existing_id IS NOT NULL THEN
            UPDATE scraper.videos SET
                views_count = GREATEST(COALESCE((v->>'views_count')::bigint, 0), scraper.videos.views_count),
                rating_score = COALESCE((v->>'rating_score')::numeric, scraper.videos.rating_score),
                updated_at = now()
            WHERE id = existing_id;
            inserted_count := inserted_count + 1;
            CONTINUE;
        END IF;

        -- Normal Insert / Upsert
        INSERT INTO scraper.videos (
            source_site,
            source_post_id,
            title,
            slug,
            detail_url,
            full_video_url,
            video_mime_type,
            trailer_preview_url,
            thumbnail_url,
            clean_thumbnail_url,
            duration_seconds,
            duration_formatted,
            views_count,
            views_raw,
            rating_score,
            rating_raw,
            categories,
            tags,
            actors,
            published_at,
            raw_payload,
            updated_at
        ) VALUES (
            (v->>'source_site'),
            (v->>'source_post_id'),
            (v->>'title'),
            (v->>'slug'),
            (v->>'detail_url'),
            (v->>'full_video_url'),
            COALESCE(v->>'video_mime_type', 'video/mp4'),
            (v->>'trailer_preview_url'),
            (v->>'thumbnail_url'),
            (v->>'clean_thumbnail_url'),
            (v->>'duration_seconds')::int,
            (v->>'duration_formatted'),
            COALESCE((v->>'views_count')::bigint, 0),
            (v->>'views_raw'),
            (v->>'rating_score')::numeric,
            (v->>'rating_raw'),
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(v->'categories', '[]'::jsonb))),
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(v->'tags', '[]'::jsonb))),
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(v->'actors', '[]'::jsonb))),
            CASE WHEN (v->>'published_at') IS NOT NULL AND (v->>'published_at') <> '' 
                 THEN (v->>'published_at')::timestamptz ELSE NULL END,
            COALESCE(v->'raw_payload', '{}'::jsonb),
            now()
        )
        ON CONFLICT (source_site, source_post_id) DO UPDATE SET
            title = EXCLUDED.title,
            slug = EXCLUDED.slug,
            detail_url = EXCLUDED.detail_url,
            full_video_url = COALESCE(EXCLUDED.full_video_url, scraper.videos.full_video_url),
            trailer_preview_url = COALESCE(EXCLUDED.trailer_preview_url, scraper.videos.trailer_preview_url),
            thumbnail_url = COALESCE(EXCLUDED.thumbnail_url, scraper.videos.thumbnail_url),
            clean_thumbnail_url = COALESCE(EXCLUDED.clean_thumbnail_url, scraper.videos.clean_thumbnail_url),
            duration_seconds = COALESCE(EXCLUDED.duration_seconds, scraper.videos.duration_seconds),
            duration_formatted = COALESCE(EXCLUDED.duration_formatted, scraper.videos.duration_formatted),
            views_count = GREATEST(EXCLUDED.views_count, scraper.videos.views_count),
            views_raw = EXCLUDED.views_raw,
            rating_score = COALESCE(EXCLUDED.rating_score, scraper.videos.rating_score),
            rating_raw = EXCLUDED.rating_raw,
            categories = EXCLUDED.categories,
            tags = EXCLUDED.tags,
            actors = EXCLUDED.actors,
            published_at = COALESCE(EXCLUDED.published_at, scraper.videos.published_at),
            raw_payload = EXCLUDED.raw_payload,
            updated_at = now();

        inserted_count := inserted_count + 1;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'count', inserted_count);
END;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_upsert_videos(jsonb) TO service_role;

-- 4. UPGRADE scraper_get_videos WITH STRICT DETERMINISTIC TIEBREAKER (id DESC)
CREATE OR REPLACE FUNCTION public.scraper_get_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      -- Category Filter
      AND (
          p_category IS NULL 
          OR lower(trim(p_category)) IN ('all', 'viral-mms')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      -- Tag / Section Filter
      AND (
          p_tag IS NULL 
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(categories)
          OR (lower(trim(p_tag)) IN ('bangladeshi', 'bangladesi') AND ('bangladesi' = ANY(categories) OR 'bangladeshi' = ANY(tags)))
          OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || lower(replace(trim(p_tag), '-', ' ')) || '%'
      )
      -- Multi-Word Search
      AND (
          p_search IS NULL 
          OR trim(p_search) = ''
          OR NOT EXISTS (
              SELECT 1
              FROM unnest(string_to_array(trim(regexp_replace(lower(p_search), '\s+', ' ', 'g')), ' ')) AS word
              WHERE word <> ''
                AND NOT (
                  lower(title) LIKE '%' || word || '%'
                  OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
                  OR lower(coalesce(array_to_string(actors, ' '), '')) LIKE '%' || word || '%'
                )
          )
      )
    ORDER BY
        CASE WHEN p_sort = 'views' THEN views_count END DESC NULLS LAST,
        CASE WHEN p_sort = 'rating' THEN rating_score END DESC NULLS LAST,
        CASE WHEN p_sort = 'longest' THEN duration_seconds END DESC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN published_at END ASC NULLS LAST,
        published_at DESC NULLS LAST,
        scraped_at DESC,
        id DESC
    LIMIT p_limit OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;

-- 5. UPGRADE scraper_get_japanese_videos WITH STRICT DETERMINISTIC TIEBREAKER (id DESC)
CREATE OR REPLACE FUNCTION public.scraper_get_japanese_videos(
    p_source_site text DEFAULT NULL,
    p_tag text DEFAULT NULL,
    p_category text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_sort text DEFAULT 'newest',
    p_limit int DEFAULT 24,
    p_offset int DEFAULT 0
)
RETURNS SETOF scraper.japanese_videos
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = scraper, public
AS $$
    SELECT * FROM scraper.japanese_videos
    WHERE (p_source_site IS NULL OR source_site = p_source_site)
      -- Category Filter
      AND (
          p_category IS NULL 
          OR lower(trim(p_category)) IN ('all', 'japanese')
          OR lower(trim(p_category)) = ANY(categories)
          OR replace(lower(trim(p_category)), ' ', '-') = ANY(categories)
      )
      -- Tag Filter
      AND (
          p_tag IS NULL 
          OR lower(trim(p_tag)) = 'all'
          OR lower(trim(p_tag)) = ANY(tags)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(tags)
          OR lower(trim(p_tag)) = ANY(categories)
          OR replace(lower(trim(p_tag)), ' ', '-') = ANY(categories)
          OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || lower(replace(trim(p_tag), '-', ' ')) || '%'
      )
      -- Multi-Word Search (maker codes like FC2, SNOS, titles, tags, actors)
      AND (
          p_search IS NULL 
          OR trim(p_search) = ''
          OR NOT EXISTS (
              SELECT 1
              FROM unnest(string_to_array(trim(regexp_replace(lower(p_search), '\s+', ' ', 'g')), ' ')) AS word
              WHERE word <> ''
                AND NOT (
                  lower(title) LIKE '%' || word || '%'
                  OR lower(replace(array_to_string(tags, ' '), '-', ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(tags, ' ')) LIKE '%' || word || '%'
                  OR lower(array_to_string(categories, ' ')) LIKE '%' || word || '%'
                  OR lower(coalesce(array_to_string(actors, ' '), '')) LIKE '%' || word || '%'
                )
          )
      )
    ORDER BY
      CASE WHEN p_sort = 'views' THEN views_count END DESC NULLS LAST,
      CASE WHEN p_sort = 'rating' THEN rating_score END DESC NULLS LAST,
      CASE WHEN p_sort = 'longest' THEN duration_seconds END DESC NULLS LAST,
      CASE WHEN p_sort = 'oldest' THEN published_at END ASC NULLS LAST,
      published_at DESC NULLS LAST,
      scraped_at DESC,
      id DESC
    LIMIT p_limit OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.scraper_get_japanese_videos(text, text, text, text, text, int, int) TO anon, authenticated, service_role;
