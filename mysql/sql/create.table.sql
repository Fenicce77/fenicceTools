-- CREATE DATABASE IF NOT EXISTS feniccedb  /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci */; 
CREATE TABLE IF NOT EXISTS `t1` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `k` bigint(20) NOT NULL DEFAULT '0',
  `host` char(120) NOT NULL DEFAULT '',
  `hostfrom` char(120) NOT NULL DEFAULT '',
  `created_ts` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `update_ts` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_internal_id` (`k`),
  KEY `idx_internal_id_created` (`k`,`created_ts`),
  KEY `idx_internal_id_updated` (`k`,`update_ts`),
  KEY `idx_host` (`host`),
  KEY `idx_hostfrom` (`hostfrom`),
  KEY `idx_k_host` (`k`,`host`),
  KEY `idx_k_hostfrom` (`k`,`hostfrom`)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
