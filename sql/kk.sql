SELECT
 members.cmp_member_id, members.biller_id, members.member_id, members.username, 
 members.first_name, members.last_name, members.email, members.join_date, members.cancelled, members.cancel_date,
 members.reinstate_date, members.affiliate_id, members.tour_id, members.subid, members.signup_ip, 
 members.signup_useragent, members.signup_browser_id, members.last_ip, members.last_useragent, members.processor_id, 
 members.signup_duration, members.signup_recurring, members.current_recurring, members.logins_members, 
 members.logins_interface, members.logins_mobile, members.logins_mobile_full, members.logins_mobile_basic, 
 members.logins_mobile_tablet, members.logins_downloader, members.logins_roku, members.last_login, 
 members.signup_zip, members.signup_country, members.signup_click, members.is_gay, members.is_limited_trial, 
 members.trial_upgrade_date, members.city, members.state, members.address, members.phone, members.biller_site_id, 
 members.biller_package_id, members.biller_member_status, members.biller_account_id, members.successful_join_id, 
 members.last_update_time, members.db, members.token, members.free_user_id, members.product_id, 
 members.signup_recurring_freq, members.trial_amount, members.trial_duration 
FROM 
 adminix.members INNER JOIN adminix.cards USING (cmp_member_id) INNER JOIN adminix.bins_extended bins ON cards.first6=bins.number COLLATE utf8_general_ci 
WHERE ( ((members.email NOT REGEXP '^.*@teamcmp.com$') AND (members.email NOT REGEXP '^.*@mad.io$')) ) 
AND (!(members.biller_id = 1 AND members.processor_id IS NULL)) 
AND (NOT EXISTS(SELECT mf.flag FROM adminix.member_flags AS mf WHERE mf.cmp_member_id = members.cmp_member_id AND mf.flag='hidden')) AND (bins.isocountry IN ('UNITED KINGDOM','UNITED STATES'))



SELECT
 members.cmp_member_id, members.biller_id, members.member_id, members.username, 
 members.first_name, members.last_name, members.email, members.join_date, members.cancelled, members.cancel_date,
 members.reinstate_date, members.affiliate_id, members.tour_id, members.subid, members.signup_ip, 
 members.signup_useragent, members.signup_browser_id, members.last_ip, members.last_useragent, members.processor_id, 
 members.signup_duration, members.signup_recurring, members.current_recurring, members.logins_members, 
 members.logins_interface, members.logins_mobile, members.logins_mobile_full, members.logins_mobile_basic, 
 members.logins_mobile_tablet, members.logins_downloader, members.logins_roku, members.last_login, 
 members.signup_zip, members.signup_country, members.signup_click, members.is_gay, members.is_limited_trial, 
 members.trial_upgrade_date, members.city, members.state, members.address, members.phone, members.biller_site_id, 
 members.biller_package_id, members.biller_member_status, members.biller_account_id, members.successful_join_id, 
 members.last_update_time, members.db, members.token, members.free_user_id, members.product_id, 
 members.signup_recurring_freq, members.trial_amount, members.trial_duration 
FROM 
 adminix.members INNER JOIN adminix.cards USING (cmp_member_id) INNER JOIN adminix.bins_extended bins ON cards.first6 = bins.number
WHERE ( ((members.email NOT REGEXP '^.*@teamcmp.com$') AND (members.email NOT REGEXP '^.*@mad.io$')) ) 
AND (!(members.biller_id = 1 AND members.processor_id IS NULL)) 
AND (NOT EXISTS(SELECT mf.flag FROM adminix.member_flags AS mf WHERE mf.cmp_member_id = members.cmp_member_id AND mf.flag='hidden')) AND (bins.isocountry IN ('UNITED KINGDOM','UNITED STATES'))