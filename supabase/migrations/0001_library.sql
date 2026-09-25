-- Apply to a new Supabase project. Each user's media remains private.
create extension if not exists pgcrypto;

create table public.folders (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  parent_id uuid,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, id),
  foreign key (owner_id, parent_id) references public.folders(owner_id, id)
);

create table public.library_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  folder_id uuid,
  title text not null check (length(trim(title)) between 1 and 200),
  kind text not null check (kind in ('gif', 'sticker')),
  source text not null check (source in ('upload', 'giphy', 'pinterest')),
  storage_path text,
  external_id text,
  favorite boolean not null default false,
  use_count integer not null default 0 check (use_count >= 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, id),
  foreign key (owner_id, folder_id) references public.folders(owner_id, id),
  check ((source = 'upload' and storage_path is not null and external_id is null)
      or (source <> 'upload' and storage_path is null and external_id is not null)),
  check (storage_path is null or storage_path like owner_id::text || '/%')
);

create index folders_owner_parent_idx on public.folders(owner_id, parent_id, sort_order);
create index library_items_owner_folder_idx on public.library_items(owner_id, folder_id, sort_order);
create index library_items_owner_favorite_idx on public.library_items(owner_id, favorite) where favorite;

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
create trigger folders_touch before update on public.folders for each row execute function public.touch_updated_at();
create trigger items_touch before update on public.library_items for each row execute function public.touch_updated_at();

alter table public.folders enable row level security;
alter table public.library_items enable row level security;
create policy folders_select on public.folders for select to authenticated using (owner_id = (select auth.uid()));
create policy folders_insert on public.folders for insert to authenticated with check (owner_id = (select auth.uid()));
create policy folders_update on public.folders for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy folders_delete on public.folders for delete to authenticated using (owner_id = (select auth.uid()));
create policy items_select on public.library_items for select to authenticated using (owner_id = (select auth.uid()));
create policy items_insert on public.library_items for insert to authenticated with check (owner_id = (select auth.uid()));
create policy items_update on public.library_items for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy items_delete on public.library_items for delete to authenticated using (owner_id = (select auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('library-media', 'library-media', false, 20971520, array['image/png', 'image/gif', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy media_select on storage.objects for select to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy media_update on storage.objects for update to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'library-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
