-- Integration checks execute inside a rolled-back transaction; no SMTP calls.
begin;
create function pg_temp.assert_mail(ev integer, entity text, expected text[]) returns void language plpgsql as $$
declare actual text[]; wanted text[];
begin
 select coalesce(array_agg(recipient order by recipient),array[]::text[]) into actual from tam_private.email_outbox where event_no=ev and entity_id=entity;
 select coalesce(array_agg(e order by e),array[]::text[]) into wanted from (select distinct lower(x) e from unnest(expected) x where x is not null) q;
 if actual is distinct from wanted then raise exception 'Event % recipient routing failed (actual %, expected %)',ev,actual,wanted; end if;
end $$;
do $$
declare applicant uuid:=gen_random_uuid(); s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); agent uuid:=gen_random_uuid(); admin uuid:=gen_random_uuid();
 app uuid:=gen_random_uuid(); req uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); admins text[]; before_count integer; final_app uuid:=gen_random_uuid();
begin
 insert into auth.users(id,email,email_confirmed_at) values
  (applicant,'tam-test-applicant@example.invalid',null),
  (s1,'tam-test-staff1@example.invalid',null),(s2,'tam-test-staff2@example.invalid',null),
  (agent,'tam-test-agent@example.invalid',null),(admin,'tam-test-admin@example.invalid',null);
 update public.profiles set role='staff' where id in(s1,s2);
 update public.profiles set role='admin' where id=admin;
 update public.profiles set role='agent',assigned_staff_id=s1 where id=agent;
 perform pg_temp.assert_mail(5,s1::text,array['tam-test-staff1@example.invalid']);
 perform pg_temp.assert_mail(10,agent::text,array['tam-test-agent@example.invalid','tam-test-staff1@example.invalid']);
 update auth.users set email_confirmed_at=now() where id=applicant;
 update auth.users set email_confirmed_at=now() where id=applicant;
 perform pg_temp.assert_mail(2,applicant::text,array['tam-test-applicant@example.invalid']);
 select array_agg(email) into admins from public.profiles where role='admin';
 insert into public.applications(id,user_id,applicant_name,email,stage) values(app,applicant,'TAM Integration Test','tam-test-applicant@example.invalid',1);
 perform pg_temp.assert_mail(6,app::text,admins||array['tam-test-applicant@example.invalid']);
 update public.applications set assigned_staff_id=s1 where id=app;
 perform pg_temp.assert_mail(7,app::text,array['tam-test-applicant@example.invalid','tam-test-staff1@example.invalid']);
 update public.applications set assigned_staff_id=s2 where id=app;
 perform pg_temp.assert_mail(8,app::text,array['tam-test-applicant@example.invalid','tam-test-staff1@example.invalid','tam-test-staff2@example.invalid']);
 update public.applications set stage=2 where id=app;
 perform pg_temp.assert_mail(12,app::text,array['tam-test-applicant@example.invalid','tam-test-staff2@example.invalid']);
 insert into public.stage_requests(id,application_id,requested_by,requested_stage,current_stage) values(req,app,s1,3,2);
 perform pg_temp.assert_mail(13,req::text,admins);
 update public.stage_requests set status='pended' where id=req;
 perform pg_temp.assert_mail(15,req::text,array['tam-test-staff1@example.invalid','tam-test-staff2@example.invalid']);
 update public.stage_requests set status='approved' where id=req;
 perform pg_temp.assert_mail(14,req::text,array['tam-test-staff1@example.invalid','tam-test-staff2@example.invalid']);
 insert into public.application_documents(id,application_id,uploaded_by,file_name) values(doc,app,applicant,'test.pdf');
 perform pg_temp.assert_mail(18,doc::text,array['tam-test-staff2@example.invalid']);
 doc:=gen_random_uuid();
 insert into public.application_documents(id,application_id,uploaded_by,file_name) values(doc,app,s2,'test.pdf');
 perform pg_temp.assert_mail(18,doc::text,array['tam-test-applicant@example.invalid']);
 doc:=gen_random_uuid();
 insert into public.application_documents(id,application_id,uploaded_by,file_name) values(doc,app,admin,'test.pdf');
 perform pg_temp.assert_mail(18,doc::text,array['tam-test-applicant@example.invalid','tam-test-staff2@example.invalid']);
 update public.applications set stage=7,status='approved' where id=app;
 perform pg_temp.assert_mail(16,app::text,array['tam-test-applicant@example.invalid','tam-test-staff2@example.invalid']);
 update public.applications set status='rejected' where id=app;
 perform pg_temp.assert_mail(17,app::text,array['tam-test-applicant@example.invalid','tam-test-staff2@example.invalid']);
 req:=gen_random_uuid();
 insert into public.delete_requests(id,application_id,requested_by) values(req,app,s1);
 perform pg_temp.assert_mail(23,req::text,admins);
 update public.delete_requests set status='rejected' where id=req;
 perform pg_temp.assert_mail(24,req::text,array['tam-test-staff1@example.invalid','tam-test-staff2@example.invalid']);
 -- Test the real RPC deletion flow, including approval mail before cascading deletion.
 req:=gen_random_uuid();
 insert into public.delete_requests(id,application_id,requested_by) values(req,app,s1);
 perform set_config('request.jwt.claim.sub',admin::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true);
 perform public.admin_delete_application(app);
 perform pg_temp.assert_mail(24,req::text,array['tam-test-staff1@example.invalid','tam-test-staff2@example.invalid']);
 perform pg_temp.assert_mail(25,app::text,array['tam-test-applicant@example.invalid','tam-test-staff2@example.invalid']);
 if exists(select 1 from public.applications where id=app) then raise exception 'Deletion RPC failed'; end if;
 delete from auth.users where id=applicant;
 perform pg_temp.assert_mail(26,applicant::text,array['tam-test-applicant@example.invalid']);
 -- Same email in multiple recipient roles and repeated attempts must produce one mail.
 perform tam_private.queue_email(999,'dedupe-test',array['SAME@example.invalid','same@example.invalid'],'Test','Test');
 perform tam_private.queue_email(999,'dedupe-test',array['same@example.invalid'],'Test','Test');
 perform pg_temp.assert_mail(999,'dedupe-test',array['same@example.invalid']);
 -- A final approval must not generate both event 12 and event 16.
 insert into public.applications(id,user_id,applicant_name,email,assigned_staff_id) values(final_app,agent,'Final Test','tam-test-applicant@example.invalid',s1);
 update public.applications set stage=7,status='approved' where id=final_app;
 perform pg_temp.assert_mail(12,final_app::text,array[]::text[]);
 perform pg_temp.assert_mail(16,final_app::text,array['tam-test-applicant@example.invalid','tam-test-staff1@example.invalid']);
 if exists(select 1 from tam_private.email_outbox where event_no in(4,9,11,19,20,21,22,27,28,29,30,31,32)) then raise exception 'Unselected event queued'; end if;
 if has_function_privilege('anon','public.tam_email_worker(text,text,uuid,uuid,boolean,text)','execute') or has_function_privilege('authenticated','public.tam_email_worker(text,text,uuid,uuid,boolean,text)','execute') then raise exception 'Worker RPC exposed to users'; end if;
 if has_schema_privilege('authenticated','tam_private','usage') then raise exception 'Private schema exposed'; end if;
end $$;
select 'PASS: selected event routing, deletion RPC, welcome deduplication, document uploader exclusion, final-approval suppression and access controls' as integration_result;
rollback;
