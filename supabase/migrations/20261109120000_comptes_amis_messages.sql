-- =====================================================================
--  BRICKS — comptes en ligne, sauvegarde, amis, progression partagée, messages
--  Sécurité : RLS partout. Chacun ne modifie que ses données et ne voit que
--  ses amis. Les actions sensibles passent par des fonctions contrôlées.
-- =====================================================================

create schema if not exists private;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------

-- Profil public : pseudo + avatar (visible seulement par soi et ses relations)
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null,
  avatar text not null default '🦊',
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  constraint profiles_username_len check (char_length(username) between 3 and 20),
  constraint profiles_username_clean check (username = btrim(username) and username !~ '[[:cntrl:]@<>]'),
  constraint profiles_avatar_len check (char_length(avatar) between 1 and 8)
);
create unique index profiles_username_lower on public.profiles (lower(username));

-- Sauvegarde complète du joueur (privée)
create table public.saves (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  constraint saves_size check (pg_column_size(data) < 500000)
);

-- Résumé de progression (visible par les amis)
create table public.progress (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint progress_size check (pg_column_size(data) < 20000)
);

-- Relations : demande en attente, amis, ou blocage
create table public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references auth.users (id) on delete cascade,
  addressee uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'blocked')),
  blocked_by uuid references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friendships_not_self check (requester <> addressee)
);
create unique index friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index friendships_requester on public.friendships (requester);
create index friendships_addressee on public.friendships (addressee);

-- Messages entre amis
create table public.messages (
  id bigint generated always as identity primary key,
  sender uuid not null references auth.users (id) on delete cascade,
  recipient uuid not null references auth.users (id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint messages_body_len check (char_length(btrim(body)) between 1 and 500),
  constraint messages_not_self check (sender <> recipient)
);
create index messages_pair on public.messages (least(sender, recipient), greatest(sender, recipient), created_at desc);
create index messages_unread on public.messages (recipient) where read_at is null;

-- ---------------------------------------------------------------------
--  Fonctions d'aide (schéma privé, non exposé par l'API)
-- ---------------------------------------------------------------------

create or replace function private.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and least(f.requester, f.addressee) = least(a, b)
      and greatest(f.requester, f.addressee) = greatest(a, b)
  );
$$;

-- Peut voir le profil de « target » : relation en cours (sauf si l'autre m'a bloqué)
create or replace function private.can_see_profile(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where least(f.requester, f.addressee) = least(auth.uid(), target)
      and greatest(f.requester, f.addressee) = greatest(auth.uid(), target)
      and (f.status <> 'blocked' or f.blocked_by = auth.uid())
  );
$$;

revoke all on function private.are_friends(uuid, uuid) from public;
revoke all on function private.can_see_profile(uuid) from public;
grant execute on function private.are_friends(uuid, uuid) to authenticated;
grant execute on function private.can_see_profile(uuid) to authenticated;

-- Création automatique du profil à l'inscription
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  uname text := btrim(coalesce(new.raw_user_meta_data ->> 'username', ''));
  ava text := left(coalesce(nullif(new.raw_user_meta_data ->> 'avatar', ''), '🦊'), 8);
begin
  if char_length(uname) < 3 or char_length(uname) > 20 then
    uname := 'player-' || substr(new.id::text, 1, 6);
  end if;
  insert into public.profiles (id, username, avatar) values (new.id, uname, ava);
  return new;
end;
$$;
revoke all on function private.handle_new_user() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Messages : anti-spam (20 / minute) et horodatage imposé par le serveur
create or replace function private.messages_before_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.messages m
      where m.sender = new.sender and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'rate_limited';
  end if;
  new.body := btrim(new.body);
  new.created_at := now();
  new.read_at := null;
  return new;
end;
$$;
revoke all on function private.messages_before_insert() from public;

create trigger messages_before_insert
  before insert on public.messages
  for each row execute function private.messages_before_insert();

-- ---------------------------------------------------------------------
--  Sécurité ligne par ligne (RLS)
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.saves enable row level security;
alter table public.progress enable row level security;
alter table public.friendships enable row level security;
alter table public.messages enable row level security;

revoke all on public.profiles, public.saves, public.progress, public.friendships, public.messages from anon;

-- Profils : soi-même ou ses relations ; on ne modifie que son pseudo, son avatar, sa présence
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.can_see_profile(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
revoke insert, update, delete on public.profiles from authenticated;
grant update (username, avatar, last_seen) on public.profiles to authenticated;

-- Sauvegardes : strictement privées
create policy saves_select on public.saves for select to authenticated
  using (user_id = (select auth.uid()));
create policy saves_insert on public.saves for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy saves_update on public.saves for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Progression : écrite par soi, lue par soi et ses amis
create policy progress_select on public.progress for select to authenticated
  using (user_id = (select auth.uid()) or private.are_friends((select auth.uid()), user_id));
create policy progress_insert on public.progress for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy progress_update on public.progress for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Relations : lecture seule (les changements passent par les fonctions ci-dessous)
create policy friendships_select on public.friendships for select to authenticated
  using ((select auth.uid()) in (requester, addressee) and (status <> 'blocked' or blocked_by = (select auth.uid())));
revoke insert, update, delete on public.friendships from authenticated;

-- Messages : seulement entre amis ; le destinataire peut seulement marquer « lu »
create policy messages_select on public.messages for select to authenticated
  using ((select auth.uid()) in (sender, recipient));
create policy messages_insert on public.messages for insert to authenticated
  with check (sender = (select auth.uid()) and private.are_friends(sender, recipient));
create policy messages_update on public.messages for update to authenticated
  using (recipient = (select auth.uid())) with check (recipient = (select auth.uid()));
revoke update, delete on public.messages from authenticated;
grant update (read_at) on public.messages to authenticated;

-- ---------------------------------------------------------------------
--  Fonctions appelées par le jeu
-- ---------------------------------------------------------------------

-- Pseudo libre ? (utilisable avant l'inscription)
create or replace function public.username_available(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.profiles p where lower(p.username) = lower(btrim(p_name)));
$$;

-- Trouver un joueur par son pseudo exact (pas de liste complète des joueurs)
create or replace function public.find_user(p_name text)
returns table (id uuid, username text, avatar text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.username, p.avatar
  from public.profiles p
  where lower(p.username) = lower(btrim(p_name))
    and p.id <> auth.uid()
    and not exists (
      select 1 from public.friendships f
      where least(f.requester, f.addressee) = least(auth.uid(), p.id)
        and greatest(f.requester, f.addressee) = greatest(auth.uid(), p.id)
        and f.status = 'blocked' and f.blocked_by = p.id
    );
$$;

-- Envoyer une demande d'ami (accepte directement si l'autre m'en avait envoyé une)
create or replace function public.send_friend_request(p_target uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  f public.friendships;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_target = me then return 'self'; end if;
  if not exists (select 1 from public.profiles where id = p_target) then return 'not_found'; end if;
  select * into f from public.friendships
    where least(requester, addressee) = least(me, p_target)
      and greatest(requester, addressee) = greatest(me, p_target);
  if found then
    if f.status = 'blocked' then
      return case when f.blocked_by = me then 'you_blocked' else 'not_found' end;
    end if;
    if f.status = 'accepted' then return 'already_friends'; end if;
    if f.requester = me then return 'already_sent'; end if;
    update public.friendships set status = 'accepted', updated_at = now() where id = f.id;
    return 'accepted';
  end if;
  insert into public.friendships (requester, addressee) values (me, p_target);
  return 'sent';
end;
$$;

-- Répondre à une demande reçue
create or replace function public.respond_friend_request(p_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_accept then
    update public.friendships set status = 'accepted', updated_at = now()
      where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end;
$$;

-- Retirer un ami ou annuler une demande envoyée
create or replace function public.remove_friend(p_other uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.friendships
  where least(requester, addressee) = least(auth.uid(), p_other)
    and greatest(requester, addressee) = greatest(auth.uid(), p_other)
    and status in ('pending', 'accepted');
$$;

-- Bloquer un joueur (supprime l'amitié, empêche demandes et messages)
create or replace function public.block_user(p_other uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if me is null or p_other = me then return; end if;
  if exists (
    select 1 from public.friendships
    where least(requester, addressee) = least(me, p_other)
      and greatest(requester, addressee) = greatest(me, p_other)
      and status = 'blocked'
  ) then return; end if;
  delete from public.friendships
    where least(requester, addressee) = least(me, p_other)
      and greatest(requester, addressee) = greatest(me, p_other);
  insert into public.friendships (requester, addressee, status, blocked_by)
    values (me, p_other, 'blocked', me);
end;
$$;

-- Débloquer
create or replace function public.unblock_user(p_other uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.friendships
  where least(requester, addressee) = least(auth.uid(), p_other)
    and greatest(requester, addressee) = greatest(auth.uid(), p_other)
    and status = 'blocked' and blocked_by = auth.uid();
$$;

-- Supprimer définitivement son compte en ligne (et toutes ses données)
create or replace function public.delete_my_account()
returns void language sql security definer set search_path = '' as $$
  delete from auth.users where id = auth.uid();
$$;

revoke all on function public.username_available(text) from public;
revoke all on function public.find_user(text) from public;
revoke all on function public.send_friend_request(uuid) from public;
revoke all on function public.respond_friend_request(bigint, boolean) from public;
revoke all on function public.remove_friend(uuid) from public;
revoke all on function public.block_user(uuid) from public;
revoke all on function public.unblock_user(uuid) from public;
revoke all on function public.delete_my_account() from public;
revoke execute on function public.username_available(text), public.find_user(text), public.send_friend_request(uuid),
  public.respond_friend_request(bigint, boolean), public.remove_friend(uuid), public.block_user(uuid),
  public.unblock_user(uuid), public.delete_my_account() from anon;

grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.find_user(text) to authenticated;
grant execute on function public.send_friend_request(uuid) to authenticated;
grant execute on function public.respond_friend_request(bigint, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.block_user(uuid) to authenticated;
grant execute on function public.unblock_user(uuid) to authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- ---------------------------------------------------------------------
--  Temps réel : nouveaux messages et demandes d'ami en direct
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.messages, public.friendships;
