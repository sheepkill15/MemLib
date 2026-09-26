-- Preserve source and rights information for saved open-license media.
alter table public.library_items
  add column if not exists source_page text,
  add column if not exists license_label text;
