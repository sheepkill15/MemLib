-- Provider media (KLIPY, Pinterest) is saved as a link: the row keeps the
-- metadata and the media URL, and no copy is stored in library-media.
-- Non-upload rows from before this migration have no media_url; they stay
-- valid, and the app ignores them because it has nothing to load.
alter table public.library_items
  drop constraint if exists library_items_source_check,
  add constraint library_items_source_check
    check (source in ('upload', 'giphy', 'klipy', 'pinterest')),
  add column if not exists media_url text,
  add column if not exists preview_url text,
  add constraint library_items_linked_media
    check ((media_url is null or media_url like 'https://%')
       and (preview_url is null or preview_url like 'https://%')
       and (source <> 'upload' or (media_url is null and preview_url is null))
       and (preview_url is null or media_url is not null));
