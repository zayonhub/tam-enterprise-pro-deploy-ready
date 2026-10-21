-- Run only after routing tests and SMTP verification pass.
update tam_private.email_settings set enabled=true where id;
select cron.schedule('tam-email-delivery','* * * * *',$cron$
 select tam_private.invoke_email_worker('run')
 where (select enabled from tam_private.email_settings where id)
 and exists (
  select 1 from tam_private.email_outbox
  where (status='pending' and available_at<=now())
     or (status='processing' and leased_at<now()-interval '5 minutes')
 );
$cron$);
