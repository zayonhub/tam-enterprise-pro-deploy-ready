begin;
do $$
declare token text; jobs jsonb; job jsonb; rejected boolean:=false; id1 uuid; id2 uuid;
begin
 -- No email sending takes place in these queue lifecycle tests.
 if exists(select 1 from tam_private.email_outbox) then raise exception 'Run queue lifecycle tests before live activation'; end if;
 select decrypted_secret into token from vault.decrypted_secrets where name='tam_email_worker_token';
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 begin
  perform public.tam_email_worker('incorrect-token','check');
 exception when insufficient_privilege then rejected:=true;
 end;
 if not rejected then raise exception 'Invalid worker token accepted'; end if;
 perform public.tam_email_worker(token,'check');
 perform tam_private.queue_email(999,'lease-a',array['lease-a@example.invalid'],'Test','Test');
 perform tam_private.queue_email(999,'lease-b',array['lease-b@example.invalid'],'Test','Test');
 jobs:=public.tam_email_worker(token,'claim');
 if jsonb_array_length(jobs)<>0 then raise exception 'Disabled worker claimed messages'; end if;
 update tam_private.email_settings set enabled=true;
 jobs:=public.tam_email_worker(token,'claim');
 if jsonb_array_length(jobs)<>2 then raise exception 'Claim failed'; end if;
 if jsonb_array_length(public.tam_email_worker(token,'claim'))<>0 then raise exception 'Concurrent claim duplicated leases'; end if;
 job:=jobs->0; id1:=(job->>'id')::uuid;
 if (public.tam_email_worker(token,'complete',id1,gen_random_uuid(),true)->>'updated')::boolean then raise exception 'Wrong lease accepted'; end if;
 perform public.tam_email_worker(token,'complete',id1,(job->>'lease')::uuid,true);
 if not exists(select 1 from tam_private.email_outbox where id=id1 and status='sent' and sent_at is not null) then raise exception 'Success state not saved'; end if;
 job:=jobs->1; id2:=(job->>'id')::uuid;
 perform public.tam_email_worker(token,'complete',id2,(job->>'lease')::uuid,false,'SMTP_FAILED');
 if not exists(select 1 from tam_private.email_outbox where id=id2 and status='pending' and available_at>now() and attempts=1) then raise exception 'Retry backoff not saved'; end if;
 update tam_private.email_outbox set available_at=now()-interval '1 minute' where id=id2;
 jobs:=public.tam_email_worker(token,'claim');
 if jsonb_array_length(jobs)<>1 then raise exception 'Retry claim failed'; end if;
 update tam_private.email_outbox set leased_at=now()-interval '10 minutes' where id=id2;
 jobs:=public.tam_email_worker(token,'claim');
 if jsonb_array_length(jobs)<>1 then raise exception 'Stale lease not recovered'; end if;
 update tam_private.email_outbox set attempts=5,leased_at=now()-interval '10 minutes' where id=id2;
 jobs:=public.tam_email_worker(token,'claim');
 if jsonb_array_length(jobs)<>0 or not exists(select 1 from tam_private.email_outbox where id=id2 and status='failed') then raise exception 'Retry limit failed'; end if;
end $$;
select 'PASS: worker authorization, disabled state, exclusive claims, lease validation, successful completion, retry backoff, stale recovery and retry limit' as worker_result;
rollback;
