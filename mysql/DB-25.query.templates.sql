-- smartico_bonus_approvals
select ba1_0.id from smartico_bonus_approvals ba1_0 where ba1_0.status = '';

[dev_pepeta_ke_promos]> explain select ba1_0.id  from   smartico_bonus_approvals ba1_0 where ba1_0.status = 'PENDING';
+----+-------------+-------+------------+------+---------------------------+---------------------------+---------+-------+------+----------+--------------------------+
| id | select_type | table | partitions | type | possible_keys             | key                       | key_len | ref   | rows | filtered | Extra                    |
+----+-------------+-------+------------+------+---------------------------+---------------------------+---------+-------+------+----------+--------------------------+
|  1 | SIMPLE      | ba1_0 | NULL       | ref  | idx_bonus_approval_status | idx_bonus_approval_status | 2       | const |    2 |   100.00 | Using where; Using index |
+----+-------------+-------+------------+------+---------------------------+---------------------------+---------+-------+------+----------+--------------------------+
1 row in set, 1 warning (0,12 sec)

[dev_pepeta_ke_promos]> explain analyze select ba1_0.id  from   smartico_bonus_approvals ba1_0 where ba1_0.status = 'PENDING'\G
*************************** 1. row ***************************
EXPLAIN: -> Filter: (ba1_0.`status` = 'PENDING')  (cost=0.45 rows=2) (actual time=0.021..0.0255 rows=2 loops=1)
    -> Covering index lookup on ba1_0 using idx_bonus_approval_status (status='PENDING')  (cost=0.45 rows=2) (actual time=0.0185..0.0225 rows=2 loops=1)




-- bonus_templates
select bt3_0.name from bonus_templates bt3_0 where  bt3_0.enabled=true and bt3_0.campaign_id is not null;

[dev_pepeta_ke_promos]> explain select bt3_0.name from bonus_templates bt3_0 where bt3_0.enabled=1 and bt3_0.campaign_id is not null;
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
| id | select_type | table | partitions | type  | possible_keys                     | key                               | key_len | ref  | rows | filtered | Extra                 |
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
|  1 | SIMPLE      | bt3_0 | NULL       | range | IDX_bonus_templates_campaignid_en | IDX_bonus_templates_campaignid_en | 9       | NULL |    1 |    12.50 | Using index condition |
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
1 row in set, 1 warning (0,18 sec)

[dev_pepeta_ke_promos]> explain analyze select bt3_0.name from bonus_templates bt3_0 where bt3_0.enabled=1 and bt3_0.campaign_id is not null\G
*************************** 1. row ***************************
EXPLAIN: -> Index range scan on bt3_0 using IDX_bonus_templates_campaignid_en over (NULL < campaign_id), with index condition: ((bt3_0.enabled = 1) and (bt3_0.campaign_id is not null))  (cost=0.71 rows=1) (actual time=0.0257..0.0305 rows=1 loops=1)

1 row in set (0,09 sec)

[dev_pepeta_ke_promos]> explain select bt3_0.name from bonus_templates bt3_0 where  bt3_0.enabled=true and bt3_0.campaign_id is not null;
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
| id | select_type | table | partitions | type  | possible_keys                     | key                               | key_len | ref  | rows | filtered | Extra                 |
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
|  1 | SIMPLE      | bt3_0 | NULL       | range | IDX_bonus_templates_campaignid_en | IDX_bonus_templates_campaignid_en | 9       | NULL |    1 |    12.50 | Using index condition |
+----+-------------+-------+------------+-------+-----------------------------------+-----------------------------------+---------+------+------+----------+-----------------------+
1 row in set, 1 warning (0,09 sec)

[dev_pepeta_ke_promos]> explain analyze select bt3_0.name from bonus_templates bt3_0 where  bt3_0.enabled=true and bt3_0.campaign_id is not null\G
*************************** 1. row ***************************
EXPLAIN: -> Index range scan on bt3_0 using IDX_bonus_templates_campaignid_en over (NULL < campaign_id), with index condition: ((bt3_0.enabled = true) and (bt3_0.campaign_id is not null))  (cost=0.71 rows=1) (actual time=0.0274..0.0738 rows=1 loops=1)

1 row in set (0,09 sec)

select bt1_0.* from bonus_templates bt1_0 where bt1_0.id=?

[dev_pepeta_ke_promos]> explain select bt1_0.* from bonus_templates bt1_0 where bt1_0.id = 4;
+----+-------------+-------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
| id | select_type | table | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra |
+----+-------------+-------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | bt1_0 | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+-------+------------+-------+---------------+---------+---------+-------+------+----------+-------+

[dev_pepeta_ke_promos]> explain analyze select bt1_0.* from bonus_templates bt1_0 where bt1_0.id = 4\G
*************************** 1. row ***************************
EXPLAIN: -> Rows fetched before execution  (cost=0..0 rows=1) (actual time=164e-6..273e-6 rows=1 loops=1)








-- smartico_bonuses
select b1_0.id from smartico_bonuses b1_0 where b1_0.profile_id=? and b1_0.smartico_bonus_id=? 

[dev_pepeta_ke_promos]> explain select * from smartico_bonuses b1_0 where b1_0.profile_id=16 and b1_0.smartico_bonus_id = 3927654;
+----+-------------+-------+------------+------+-------------------------------------------------------------------------------------------+-----------------------+---------+-------+------+----------+-------------+
| id | select_type | table | partitions | type | possible_keys                                                                             | key                   | key_len | ref   | rows | filtered | Extra       |
+----+-------------+-------+------------+------+-------------------------------------------------------------------------------------------+-----------------------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | b1_0  | NULL       | ref  | idx_smartico_bonus_id,idx_smartico_profile,idx_smartico_bonuses_profile_smartico_bonus_id | idx_smartico_bonus_id | 9       | const |    1 |    20.00 | Using where |
+----+-------------+-------+------------+------+-------------------------------------------------------------------------------------------+-----------------------+---------+-------+------+----------+-------------+
1 row in set, 1 warning (0,10 sec)

[dev_pepeta_ke_promos]> explain analyze select * from smartico_bonuses b1_0 where b1_0.profile_id=16 and b1_0.smartico_bonus_id = 3927654\G
*************************** 1. row ***************************
EXPLAIN: -> Filter: (b1_0.profile_id = 16)  (cost=0.27 rows=0.2) (actual time=0.0274..0.0291 rows=1 loops=1)
    -> Index lookup on b1_0 using idx_smartico_bonus_id (smartico_bonus_id=3927654)  (cost=0.27 rows=1) (actual time=0.0257..0.0272 rows=1 loops=1)

[dev_pepeta_ke_promos]> explain analyze select * from smartico_bonuses b1_0 where b1_0.profile_id=16 and b1_0.smartico_bonus_id = 3927654\G
*************************** 1. row ***************************
EXPLAIN: -> Filter: (b1_0.profile_id = 16)  (cost=0.27 rows=0.2) (actual time=0.0274..0.0291 rows=1 loops=1)
    -> Index lookup on b1_0 using idx_smartico_bonus_id (smartico_bonus_id=3927654)  (cost=0.27 rows=1) (actual time=0.0257..0.0272 rows=1 loops=1)

1 row in set (0,24 sec)

[dev_pepeta_ke_promos]> explain select * from smartico_bonuses b1_0 use index(idx_smartico_bonuses_profile_smartico_bonus_id) where b1_0.profile_id=16 and b1_0.smartico_bonus_id = 3927654;
+----+-------------+-------+------------+------+------------------------------------------------+------------------------------------------------+---------+-------------+------+----------+-------+
| id | select_type | table | partitions | type | possible_keys                                  | key                                            | key_len | ref         | rows | filtered | Extra |
+----+-------------+-------+------------+------+------------------------------------------------+------------------------------------------------+---------+-------------+------+----------+-------+
|  1 | SIMPLE      | b1_0  | NULL       | ref  | idx_smartico_bonuses_profile_smartico_bonus_id | idx_smartico_bonuses_profile_smartico_bonus_id | 17      | const,const |    1 |   100.00 | NULL  |
+----+-------------+-------+------------+------+------------------------------------------------+------------------------------------------------+---------+-------------+------+----------+-------+
1 row in set, 1 warning (0,13 sec)

[dev_pepeta_ke_promos]> explain analyze select * from smartico_bonuses b1_0 use index(idx_smartico_bonuses_profile_smartico_bonus_id) where b1_0.profile_id=16 and b1_0.smartico_bonus_id = 3927654\G
*************************** 1. row ***************************
EXPLAIN: -> Index lookup on b1_0 using idx_smartico_bonuses_profile_smartico_bonus_id (profile_id=16, smartico_bonus_id=3927654)  (cost=0.35 rows=1) (actual time=0.03..0.0317 rows=1 loops=1)

1 row in set (0,09 sec)



