-- Stable provider identity is separate from the stored media path and source page.
alter table public.library_items
  add column if not exists source_type text,
  add column if not exists source_id text;

update public.library_items
set source_type = case
      when source_page like 'https://giphy.com/gifs/%' then 'giphy'
      else 'upload'
    end,
    source_id = case
      when source_page like 'https://giphy.com/gifs/%'
        then coalesce(nullif(substring(source_page from '([A-Za-z0-9]+)$'), ''), id::text)
      else id::text
    end
where source_type is null or source_id is null;

alter table public.library_items
  alter column source_type set not null,
  alter column source_id set not null,
  add constraint library_items_source_identity_nonempty
    check (length(trim(source_type)) > 0 and length(trim(source_id)) > 0);

create index library_items_owner_source_identity_idx
  on public.library_items (owner_id, source_type, source_id);
