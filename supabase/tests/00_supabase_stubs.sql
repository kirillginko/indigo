-- The parts of a Supabase project the migrations lean on, stubbed so the schema
-- can be exercised against a plain Postgres. Not a simulation of Supabase — just
-- enough of its roles, storage and Vault for the migrations to mean something.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema if not exists extensions;
create schema if not exists storage;

create table if not exists storage.buckets (id text primary key, name text, public boolean);
create table if not exists storage.objects (id uuid default gen_random_uuid(), bucket_id text);
alter table storage.objects enable row level security;

create schema if not exists vault;
create table if not exists vault.secrets (
    id uuid primary key default gen_random_uuid(), name text unique, secret text, description text);
create or replace view vault.decrypted_secrets as
    select id, name, secret as decrypted_secret, description from vault.secrets;
create or replace function vault.create_secret(p_secret text, p_name text, p_description text default '')
returns uuid language sql as $$
    insert into vault.secrets (name, secret, description)
    values (p_name, p_secret, p_description) returning id;
$$;
create or replace function vault.update_secret(p_id uuid, p_secret text, p_name text, p_description text default '')
returns void language sql as $$
    update vault.secrets set secret = p_secret, name = p_name, description = p_description where id = p_id;
$$;
