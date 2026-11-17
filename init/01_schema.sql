-- 源库固定结构：制品目录（只允许对这四张固定列做增/改/删，不允许 DDL）
CREATE TABLE IF NOT EXISTS artifacts (
    artifact_no  INTEGER PRIMARY KEY,
    service_name TEXT    NOT NULL,
    version      TEXT    NOT NULL,
    sha256       TEXT    NOT NULL
);

-- 仅在空表时写入示例数据，重启不会重复播种
INSERT INTO artifacts (artifact_no, service_name, version, sha256)
SELECT v.artifact_no, v.service_name, v.version, v.sha256
FROM (VALUES
    (1001, 'billing-gateway', '1.4.2', 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90'),
    (1002, 'risk-engine',      '2.7.0', '0f1e2d3c4b5a69788796a5b4c3d2e1f009182736455463728190aabbccddeeff'),
    (1003, 'notify-hub',       '0.9.3', 'ffeeddccbbaa9988776655443322110099887766554433221100998877665544')
) AS v(artifact_no, service_name, version, sha256)
WHERE NOT EXISTS (SELECT 1 FROM artifacts);

-- 网页成组操作的事务来源登记：
-- 网页先生成操作号（operation_id），apply_operations 在与目录修改
-- *同一个源事务* 内写入本表，因此来源记录与该事务的目录修改同成败：
--   * 事务提交 → 登记与目录修改一起可见；
--   * 事务回滚 → 登记一并消失，不留下任何可查来源；
--   * 普通 SQL 直接改目录 → 本表无记录（来源未登记，且不能据此断言写入者）。
-- xid 为写入时的当前事务号，供逻辑流按事务关联，防止来源串到相邻事务。
CREATE TABLE IF NOT EXISTS operation_origins (
    operation_id TEXT PRIMARY KEY,
    xid          BIGINT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
