begin;
do $$
declare p uuid; pisti uuid; gabor uuid; bass uuid; voice uuid; keys text[];
begin
 insert into public.license_products(product_id,name) values('soundlift-test-flags','SoundLift flag test')
 on conflict(product_id) do update set name=excluded.name returning id into p;
 insert into public.licenses(product_id,key_hash,customer_name,customer_discord_id)
 values(p,repeat('1',64),'Pisti','111111111111111') returning id into pisti;
 insert into public.licenses(product_id,key_hash,customer_name,customer_discord_id)
 values(p,repeat('2',64),'Gábor','222222222222222') returning id into gabor;
 select id into bass from public.soundlift_features where feature_key='extra_bass_pro';
 select id into voice from public.soundlift_features where feature_key='voice_boost';
 insert into public.soundlift_license_features(license_id,feature_id) values(pisti,bass),(gabor,voice);
 select array_agg(feature_key order by feature_key) into keys from public.get_soundlift_license_features(pisti);
 if keys <> array['extra_bass_pro'] then raise exception 'Pisti isolation failed: %',keys; end if;
 select array_agg(feature_key order by feature_key) into keys from public.get_soundlift_license_features(gabor);
 if keys <> array['voice_boost'] then raise exception 'Gabor isolation failed: %',keys; end if;
end $$;
rollback;
