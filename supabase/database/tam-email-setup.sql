create schema if not exists tam_private;
revoke all on schema tam_private from public, anon, authenticated;
grant usage on schema tam_private to service_role;
create extension if not exists pg_net;
create extension if not exists pg_cron;
create table tam_private.email_outbox (
 id uuid primary key default gen_random_uuid(), event_no integer not null,
 entity_id text not null, recipient text not null, subject text not null, body text not null,
 dedupe_key text not null unique, status text not null default 'pending'
 check (status in ('pending','processing','sent','failed')),
 attempts integer not null default 0, available_at timestamptz not null default now(),
 lease uuid, leased_at timestamptz, sent_at timestamptz, last_error text,
 created_at timestamptz not null default now()
);
alter table tam_private.email_outbox enable row level security;
create index email_outbox_pending_idx on tam_private.email_outbox(available_at) where status in ('pending','processing');
create table tam_private.email_settings(id boolean primary key default true check(id), enabled boolean not null default false);
alter table tam_private.email_settings enable row level security;
insert into tam_private.email_settings values(true,false);
do $$ begin
 if not exists(select 1 from vault.secrets where name='tam_email_worker_token') then
  perform vault.create_secret(gen_random_uuid()::text || gen_random_uuid()::text,'tam_email_worker_token');
 end if;
end $$;

create function tam_private.email_worker(p_token text,p_op text,p_id uuid default null,p_lease uuid default null,p_success boolean default false,p_error text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; secret text;
begin
 if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then raise exception 'Forbidden' using errcode='42501'; end if;
 select decrypted_secret into secret from vault.decrypted_secrets where name='tam_email_worker_token';
 if p_token is null or secret is null or p_token<>secret then raise exception 'Forbidden' using errcode='42501'; end if;
 if p_op='check' then return jsonb_build_object('authorized',true,'enabled',(select enabled from tam_private.email_settings where id)); end if;
 if p_op='claim' then
  if not (select enabled from tam_private.email_settings where id) then return '[]'::jsonb; end if;
  update tam_private.email_outbox set status='failed',last_error='retry_limit' where attempts>=5 and status in ('pending','processing') and (status='pending' or leased_at<now()-interval '5 minutes');
  with picked as (
   select id from tam_private.email_outbox where attempts<5 and ((status='pending' and available_at<=now()) or (status='processing' and leased_at<now()-interval '5 minutes'))
   order by created_at for update skip locked limit 5
  ), claimed as (
   update tam_private.email_outbox o set status='processing',attempts=attempts+1,lease=gen_random_uuid(),leased_at=now()
   from picked where o.id=picked.id returning o.*
  ) select coalesce(jsonb_agg(to_jsonb(claimed)),'[]'::jsonb) into result from claimed;
  return result;
 elsif p_op='complete' then
  update tam_private.email_outbox set status=case when p_success then 'sent' when attempts>=5 then 'failed' else 'pending' end,
   sent_at=case when p_success then now() else null end,
   last_error=case when p_success then null else left(coalesce(p_error,'delivery_failed'),100) end,
   available_at=now()+make_interval(secs=>least(3600,60*power(2,attempts)::integer)),lease=null,leased_at=null
   where id=p_id and lease=p_lease and status='processing';
  return jsonb_build_object('updated',found);
 end if;
 raise exception 'Unknown operation';
end $$;
revoke all on function tam_private.email_worker(text,text,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function tam_private.email_worker(text,text,uuid,uuid,boolean,text) to service_role;
create function public.tam_email_worker(p_token text,p_op text,p_id uuid default null,p_lease uuid default null,p_success boolean default false,p_error text default null)
returns jsonb language sql security invoker set search_path='' as $$ select tam_private.email_worker(p_token,p_op,p_id,p_lease,p_success,p_error); $$;
revoke all on function public.tam_email_worker(text,text,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.tam_email_worker(text,text,uuid,uuid,boolean,text) to service_role;

create function tam_private.invoke_email_worker(p_mode text default 'run') returns bigint language plpgsql security definer set search_path='' as $$
declare secret text; request_id bigint;
begin
 select decrypted_secret into secret from vault.decrypted_secrets where name='tam_email_worker_token';
 select net.http_post(url:='https://asupemsmwzrovucpvqyt.supabase.co/functions/v1/tam-email-worker',
 headers:=jsonb_build_object('Content-Type','application/json','x-worker-token',secret),
 body:=jsonb_build_object('mode',p_mode),timeout_milliseconds:=120000) into request_id;
 return request_id;
end $$;
revoke all on function tam_private.invoke_email_worker(text) from public,anon,authenticated,service_role;

-- Only future committed changes generate mail. Auth verification and recovery
-- continue to use the existing Supabase Auth SMTP configuration (events 1, 3).
alter table public.profiles add column if not exists assigned_staff_id uuid references public.profiles(id) on delete set null;

create function tam_private.queue_email(p_event integer,p_entity text,p_recipients text[],p_subject text,p_body text,p_exclude text default null)
returns void language plpgsql security definer set search_path='' as $$
begin
 insert into tam_private.email_outbox(event_no,entity_id,recipient,subject,body,dedupe_key)
 select p_event,p_entity,email,p_subject,p_body,
  p_event::text||':'||p_entity||':'||txid_current()::text||':'||email
 from (select distinct lower(btrim(x)) email from unnest(p_recipients) x) recipients
 where email ~ '^[^[:space:]<>@]+@[^[:space:]<>@]+[.][^[:space:]<>@]+$'
 and (p_exclude is null or email<>lower(btrim(p_exclude)))
 on conflict(dedupe_key) do nothing;
end $$;
revoke all on function tam_private.queue_email(integer,text,text[],text,text,text) from public,anon,authenticated,service_role;

create function tam_private.profile_email(p_id uuid) returns text language sql stable security definer set search_path='' as $$
 select email from public.profiles where id=p_id;
$$;
revoke all on function tam_private.profile_email(uuid) from public,anon,authenticated,service_role;

create function tam_private.application_email_event() returns trigger language plpgsql security definer set search_path='' as $$
declare a record; recipients text[]; admins text[]; staff text; previous_staff text; context text; labels text[];
begin
 if TG_OP='DELETE' then a:=OLD; else a:=NEW; end if;
 staff:=tam_private.profile_email(a.assigned_staff_id);
 recipients:=array[a.email,staff];
 context:='Applicant: '||a.applicant_name||E'\nApplication reference: '||left(a.id::text,8);
 labels:=array['Onboarding Complete','Document Preparation','Profile Submitted','Pool Monitoring','ITA Received','Application Submitted','Approved'];
 if TG_OP='INSERT' then
  select array_agg(email) into admins from public.profiles where role='admin';
  perform tam_private.queue_email(6,a.id::text,recipients||coalesce(admins,array[]::text[]),'Application submitted',E'Your application has been submitted successfully.\n\n'||context);
  if a.assigned_staff_id is not null then
   perform tam_private.queue_email(7,a.id::text,recipients,'Staff assigned to your application',E'A staff member has been assigned to handle this application.\n\n'||context);
  end if;
 elsif TG_OP='UPDATE' then
  if OLD.assigned_staff_id is distinct from NEW.assigned_staff_id then
   previous_staff:=tam_private.profile_email(OLD.assigned_staff_id);
   perform tam_private.queue_email(case when OLD.assigned_staff_id is null then 7 else 8 end,a.id::text,
    recipients||array[previous_staff],case when OLD.assigned_staff_id is null then 'Staff assigned to your application' else 'Application staff assignment changed' end,
    'Staff assignment updated.'||E'\nCurrent staff: '||coalesce((select full_name from public.profiles where id=a.assigned_staff_id),'Not assigned')||E'\n\n'||context);
  end if;
  if (OLD.status is distinct from NEW.status and NEW.status='approved') or (OLD.stage is distinct from NEW.stage and NEW.stage=7) then
   perform tam_private.queue_email(16,a.id::text,recipients,'Application approved',E'This application has been marked approved in the NonStop Travels portal.\n\n'||context);
  elsif OLD.status is distinct from NEW.status and NEW.status='rejected' then
   perform tam_private.queue_email(17,a.id::text,recipients,'Application status update',E'This application has been marked rejected in the NonStop Travels portal. Please contact your assigned staff member for clarification.\n\n'||context);
  elsif OLD.stage is distinct from NEW.stage then
   perform tam_private.queue_email(12,a.id::text,recipients,'Application progress update','Current stage: '||coalesce(labels[a.stage],a.stage::text)||E'\n\n'||context);
  end if;
 elsif TG_OP='DELETE' then
  perform tam_private.queue_email(25,a.id::text,recipients,'Application deleted',E'This application has been deleted from the NonStop Travels portal.\n\n'||context);
 end if;
 return coalesce(NEW,OLD);
end $$;
revoke all on function tam_private.application_email_event() from public,anon,authenticated,service_role;
create trigger tam_email_application_changes after insert or update or delete on public.applications for each row execute function tam_private.application_email_event();

create function tam_private.profile_email_event() returns trigger language plpgsql security definer set search_path='' as $$
declare recipients text[]; context text;
begin
 if TG_OP='DELETE' then
  perform tam_private.queue_email(26,OLD.id::text,array[OLD.email],'Account deleted','Your NonStop Travels account has been deleted.');
  return OLD;
 end if;
 if OLD.role is distinct from NEW.role then
  perform tam_private.queue_email(5,NEW.id::text,array[NEW.email],'Account role updated','Your NonStop Travels account role is now: '||coalesce(NEW.role,'applicant')||'.');
 end if;
 if NEW.role='agent' and NEW.assigned_staff_id is not null and (OLD.assigned_staff_id is distinct from NEW.assigned_staff_id or OLD.role is distinct from NEW.role) then
  perform tam_private.queue_email(10,NEW.id::text,array[NEW.email,tam_private.profile_email(NEW.assigned_staff_id)],'Agent supervisor assignment',
   'Agent: '||coalesce(NEW.full_name,NEW.email)||E'\nSupervising staff: '||coalesce((select full_name from public.profiles where id=NEW.assigned_staff_id),'Assigned staff member'));
 end if;
 return NEW;
end $$;
revoke all on function tam_private.profile_email_event() from public,anon,authenticated,service_role;
create trigger tam_email_profile_changes before update or delete on public.profiles for each row execute function tam_private.profile_email_event();

create function tam_private.welcome_email_event() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if NEW.email_confirmed_at is not null and (TG_OP='INSERT' or OLD.email_confirmed_at is null) then
  perform tam_private.queue_email(2,NEW.id::text,array[NEW.email],'Welcome to NonStop Travels',E'Your email has been verified. Welcome to NonStop Travels.\n\nYou can sign in to your portal to submit an application, upload documents and follow your application progress.');
 end if;
 return NEW;
end $$;
revoke all on function tam_private.welcome_email_event() from public,anon,authenticated,service_role;
create trigger tam_email_welcome after insert or update of email_confirmed_at on auth.users for each row execute function tam_private.welcome_email_event();

create function tam_private.request_email_event() returns trigger language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; recipients text[]; admins text[]; context text; event_num integer; title text;
begin
 select * into a from public.applications where id=NEW.application_id;
 if not found then return NEW; end if;
 context:='Applicant: '||a.applicant_name||E'\nApplication reference: '||left(a.id::text,8);
 if TG_OP='INSERT' and NEW.status='pending' then
  select array_agg(email) into recipients from public.profiles where role='admin';
  event_num:=case when TG_TABLE_NAME='stage_requests' then 13 else 23 end;
  title:=case when TG_TABLE_NAME='stage_requests' then 'Stage advancement requested' else 'Application deletion requested' end;
 elsif TG_OP='UPDATE' and OLD.status is distinct from NEW.status and NEW.status in ('approved','pended','rejected') then
  recipients:=array[tam_private.profile_email(NEW.requested_by),tam_private.profile_email(a.assigned_staff_id)];
  event_num:=case when TG_TABLE_NAME='delete_requests' then 24 when NEW.status='approved' then 14 else 15 end;
  title:=case when TG_TABLE_NAME='stage_requests' then 'Stage advancement request: ' else 'Application deletion request: ' end||case when NEW.status='pended' then 'put on hold' else NEW.status end;
 else return NEW;
 end if;
 perform tam_private.queue_email(event_num,NEW.id::text,recipients,title,title||E'.\n\n'||context);
 return NEW;
end $$;
revoke all on function tam_private.request_email_event() from public,anon,authenticated,service_role;
create trigger tam_email_stage_requests after insert or update on public.stage_requests for each row execute function tam_private.request_email_event();
create trigger tam_email_delete_requests after insert or update on public.delete_requests for each row execute function tam_private.request_email_event();

create function tam_private.document_email_event() returns trigger language plpgsql security definer set search_path='' as $$
declare a public.applications%rowtype; uploader text; recipients text[];
begin
 select * into a from public.applications where id=NEW.application_id;
 if not found then return NEW; end if;
 uploader:=tam_private.profile_email(NEW.uploaded_by);
 if lower(coalesce(uploader,''))=lower(a.email) then
  recipients:=array[tam_private.profile_email(a.assigned_staff_id)];
 else
  recipients:=array[a.email,tam_private.profile_email(a.assigned_staff_id)];
 end if;
 perform tam_private.queue_email(18,NEW.id::text,recipients,'New document uploaded',
  E'A document has been uploaded to this application. Sign in to the portal to review it.\n\nApplicant: '||a.applicant_name||E'\nApplication reference: '||left(a.id::text,8),uploader);
 return NEW;
end $$;
revoke all on function tam_private.document_email_event() from public,anon,authenticated,service_role;
create trigger tam_email_document_upload after insert on public.application_documents for each row execute function tam_private.document_email_event();

-- The existing UI deletes applications via this function without first marking
-- the request approved. Record that decision before the request is removed.
create or replace function public.admin_delete_application(app_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
  raise exception 'Only admins can delete applications';
 end if;
 update public.delete_requests set status='approved' where application_id=app_id and status='pending';
 delete from public.notes where application_id=app_id;
 delete from public.application_documents where application_id=app_id;
 delete from public.stage_requests where application_id=app_id;
 delete from public.delete_requests where application_id=app_id;
 delete from public.activity_logs where application_id=app_id;
 delete from public.applications where id=app_id;
end $$;
revoke all on function public.admin_delete_application(uuid) from public,anon;
grant execute on function public.admin_delete_application(uuid) to authenticated;

-- Close the existing unauthenticated role-changing RPC before enabling role
-- notification delivery. The public signature stays compatible with TAM.
create or replace function public.update_user_role(target_user_id uuid,new_role text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='admin') then
  raise exception 'Only admins can change account roles' using errcode='42501';
 end if;
 if new_role not in ('applicant','staff','agent','admin') or new_role is null then
  raise exception 'Invalid account role';
 end if;
 update public.profiles set role=new_role where id=target_user_id;
end $$;
revoke all on function public.update_user_role(uuid,text) from public,anon;
grant execute on function public.update_user_role(uuid,text) to authenticated;
-- Explicit deny policies document that the private mail queue is not a client API.
create policy email_outbox_deny_clients on tam_private.email_outbox for all to anon,authenticated using(false) with check(false);
create policy email_settings_deny_clients on tam_private.email_settings for all to anon,authenticated using(false) with check(false);
