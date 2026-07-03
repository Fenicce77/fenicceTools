CREATE DATABASE IF NOT EXISTS `feniccedb` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci */ /*!80016 DEFAULT ENCRYPTION='N' */;
use feniccedb;
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
  KEY `idx_host_created` (`host`,`created_ts`),
  KEY `idx_host_update` (`host`,`update_ts`),
  KEY `idx_hostfrom_update` (`hostfrom`,`update_ts`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci ;


-- pt-online-schema-change --recursion-method=none --no-analyze-before-swap --no-check-replication-filters --socket=/var/lib/mysql/mysql.sock --alter "add key idx_hostfrom_create(hostfrom,created_ts)" --max-load Threads_running=100,Threads_connected=300 --critical-load Threads_connected=300 D=feniccedb,t=t1,h=localhost --dry-run