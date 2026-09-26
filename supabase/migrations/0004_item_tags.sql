-- Preserve existing libraries while enabling custom tags on synced items.
alter table public.library_items
  add column if not exists tags text[] not null default '{}';
