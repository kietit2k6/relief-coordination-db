/* =====================================================================
   08_monitoring.sql — Giám sát: bộ index đề xuất sau các lab, đo lại bộ
   truy vấn nghiệp vụ (so với baseline của 03), Query Store top truy vấn theo
   logical reads, index usage, fragmentation, index không thấy lượt đọc.
   Đầu vào: lab.usp_ResetLab + BỘ INDEX ĐỀ XUẤT (công bố):
     IXReliefRequestRegionStatus  (báo cáo)  – Ca 3, Q02
     IXDispatchOrderWarehouseItem (báo cáo)  – Q06, phân trang lịch sử xuất
     IXDispatchOrderRequest       (Ca 1)     – Q03, Q04
     IXAuditLogWarehouseTime      (Lab 07)   – Q08 phân trang AuditLog
     IXReliefRequestPending       (filtered) – thêm vào để kiểm tra: khi đã có
                                               index báo cáo, nó có được dùng không?
   Lưu ý: sys.dm_db_index_usage_stats của một index bắt đầu đếm từ lúc index
   được tạo (hoặc từ lần khởi động SQL Server), nên "phiên lab" ở đây = từ lúc
   tạo bộ index đề xuất bên dưới đến khi chạy xong script này.
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseItem
    ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID);
CREATE NONCLUSTERED INDEX IXDispatchOrderRequest
    ON dbo.DispatchOrder (RequestID) INCLUDE (DispatchedQty);
CREATE NONCLUSTERED INDEX IXAuditLogWarehouseTime
    ON dbo.AuditLog (WarehouseID, LoggedAt) INCLUDE (ItemID, ActionType, DeltaQty);
CREATE NONCLUSTERED INDEX IXReliefRequestPending
    ON dbo.ReliefRequest (RegionID, CreatedAt) INCLUDE (ItemID, RequestedQty)
    WHERE Status = 'Pending';
GO
/* ---------------------------------------------------------------------
   M1. Đo lại bộ truy vấn nghiệp vụ với cùng tham số như baseline (03)
   --------------------------------------------------------------------- */
EXEC lab.usp_MeasureQ 'FINAL-Q01', 'R1 hot',  'Q01', N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'FINAL-Q01', 'R16 low', 'Q01', N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'FINAL-Q02', 'all',     'Q02';
EXEC lab.usp_MeasureQ 'FINAL-Q03', 'all',     'Q03';
EXEC lab.usp_MeasureQ 'FINAL-Q04', 'all',     'Q04';
EXEC lab.usp_MeasureQ 'FINAL-Q05', 'R20 item1', 'Q05', N'@RegionID = 20, @ItemID = 1';
EXEC lab.usp_MeasureQ 'FINAL-Q06', 'W1 I14 Q2', 'Q06', N'@WarehouseID = 1, @ItemID = 14, @From = ''2025-04-01'', @To = ''2025-07-01''';
EXEC lab.usp_MeasureQ 'FINAL-Q07', 'Q2-2025',   'Q07', N'@From = ''2025-04-01'', @To = ''2025-07-01''';
EXEC lab.usp_MeasureQ 'FINAL-Q08', 'W5 page3',  'Q08', N'@WarehouseID = 5, @Skip = 100';
GO
PRINT N'== M1. Baseline (03, chỉ PK) so với bộ index đề xuất — cùng truy vấn, cùng tham số ==';
DECLARE @pass INT = (SELECT PassNo FROM lab.RunContext);
SELECT REPLACE(b.CaseID, 'BASE-', '') AS QueryID, b.Variant, b.RowsReturned,
       b.MedianReads AS BaselineReads, f.MedianReads AS FinalReads,
       CAST(100.0 * (b.MedianReads - f.MedianReads) / NULLIF(b.MedianReads, 0) AS DECIMAL(6,1)) AS ReadsReductionPct,
       b.MedianCpuMs AS BaselineCpuMs, f.MedianCpuMs AS FinalCpuMs,
       b.MedianElapsedMs AS BaselineElapsedMs, f.MedianElapsedMs AS FinalElapsedMs,
       IIF(fb.BagHash = ff.BagHash AND fb.OrderHash = ff.OrderHash, 1, 0) AS SameResult
FROM lab.vMeasureSummary b
JOIN lab.vMeasureSummary f ON f.PassNo = b.PassNo AND f.CaseID = REPLACE(b.CaseID, 'BASE-', 'FINAL-') AND f.Variant = b.Variant
OUTER APPLY (SELECT TOP (1) BagHash, OrderHash FROM lab.Fingerprint x WHERE x.PassNo = b.PassNo AND x.CaseID = b.CaseID AND x.Variant = b.Variant ORDER BY x.FingerprintID DESC) fb
OUTER APPLY (SELECT TOP (1) BagHash, OrderHash FROM lab.Fingerprint x WHERE x.PassNo = f.PassNo AND x.CaseID = f.CaseID AND x.Variant = f.Variant ORDER BY x.FingerprintID DESC) ff
WHERE b.PassNo = @pass AND b.CaseID LIKE 'BASE-%'
ORDER BY QueryID, b.Variant;
GO
/* ---------------------------------------------------------------------
   M2. Query Store — top truy vấn theo logical reads trong khoảng đo của lượt này
   Khoảng đo = từ số đo đầu tiên của lượt (lab.Measurement) đến hiện tại, làm tròn
   theo các interval 5 phút của Query Store (in ra start/end thực tế).
   Bỏ các câu lệnh của schema lab, câu băm kết quả của harness và truy vấn hệ thống
   (vẫn giữ các câu kiểm tra nghiệp vụ, CREATE INDEX của lab vì chúng là tải thật).
   --------------------------------------------------------------------- */
EXEC sys.sp_query_store_flush_db;
GO
DECLARE @pass INT = (SELECT PassNo FROM lab.RunContext);
DECLARE @fromLocal DATETIME2 = (SELECT MIN(MeasuredAt) FROM lab.Measurement WHERE PassNo = @pass);
DECLARE @from DATETIMEOFFSET = TODATETIMEOFFSET(@fromLocal, DATEPART(TZOFFSET, SYSDATETIMEOFFSET()));
IF OBJECT_ID('tempdb..#qs') IS NOT NULL DROP TABLE #qs;
SELECT p.query_id,
       SUM(rs.count_executions) AS Executions,
       SUM(rs.avg_logical_io_reads * rs.count_executions) AS TotalReads,
       SUM(rs.avg_cpu_time * rs.count_executions) / 1000.0 AS TotalCpuMs,
       SUM(rs.avg_duration * rs.count_executions) / 1000.0 AS TotalDurationMs,
       MIN(i.start_time) AS IntervalStart, MAX(i.end_time) AS IntervalEnd,
       COUNT(DISTINCT p.plan_id) AS Plans
INTO #qs
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval i ON i.runtime_stats_interval_id = rs.runtime_stats_interval_id
JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
WHERE rs.last_execution_time >= @from
GROUP BY p.query_id;
PRINT N'== M2a. Khoảng đo Query Store ==';
SELECT @fromLocal AS FirstMeasurementOfPass, MIN(IntervalStart) AS QS_IntervalStart, MAX(IntervalEnd) AS QS_IntervalEnd,
       SUM(Executions) AS ExecutionsAllQueries FROM #qs;
PRINT N'== M2b. Top 15 theo TỔNG logical reads (tổng = trung bình x số lần chạy) ==';
SELECT TOP (15) s.query_id,
       COALESCE(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(ad hoc)') AS ObjectName,
       LEFT(REPLACE(REPLACE(t.query_sql_text, CHAR(13), N' '), CHAR(10), N' '), 90) AS QueryText,
       s.Executions, CAST(s.TotalReads AS BIGINT) AS TotalLogicalReads,
       CAST(s.TotalReads / NULLIF(s.Executions, 0) AS DECIMAL(12,1)) AS AvgReadsPerExec,
       CAST(s.TotalCpuMs / NULLIF(s.Executions, 0) AS DECIMAL(10,2)) AS AvgCpuMs,
       CAST(s.TotalDurationMs / NULLIF(s.Executions, 0) AS DECIMAL(10,2)) AS AvgDurationMs, s.Plans
FROM #qs s JOIN sys.query_store_query q ON q.query_id = s.query_id
JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
WHERE ISNULL(OBJECT_SCHEMA_NAME(q.object_id), N'') <> N'lab'
  AND t.query_sql_text NOT LIKE N'%sys.%' AND t.query_sql_text NOT LIKE N'%lab.%'
  AND t.query_sql_text NOT LIKE N'%lab[_]rn%'          -- câu băm kết quả của harness (##lab_fp)
ORDER BY s.TotalReads DESC;
PRINT N'== M2c. Top 10 theo logical reads TRUNG BÌNH mỗi lần chạy ==';
SELECT TOP (10) s.query_id,
       COALESCE(OBJECT_SCHEMA_NAME(q.object_id) + N'.' + OBJECT_NAME(q.object_id), N'(ad hoc)') AS ObjectName,
       LEFT(REPLACE(REPLACE(t.query_sql_text, CHAR(13), N' '), CHAR(10), N' '), 90) AS QueryText,
       s.Executions, CAST(s.TotalReads / NULLIF(s.Executions, 0) AS DECIMAL(12,1)) AS AvgReadsPerExec,
       CAST(s.TotalReads AS BIGINT) AS TotalLogicalReads
FROM #qs s JOIN sys.query_store_query q ON q.query_id = s.query_id
JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
WHERE ISNULL(OBJECT_SCHEMA_NAME(q.object_id), N'') <> N'lab'
  AND t.query_sql_text NOT LIKE N'%sys.%' AND t.query_sql_text NOT LIKE N'%lab.%'
  AND t.query_sql_text NOT LIKE N'%lab[_]rn%'          -- câu băm kết quả của harness (##lab_fp)
ORDER BY s.TotalReads / NULLIF(s.Executions, 0) DESC;
GO
/* ---------------------------------------------------------------------
   M3. Index usage (từ lúc tạo bộ index đề xuất ở đầu script)
   --------------------------------------------------------------------- */
PRINT N'== M3. Index usage trên bảng dbo ==';
SELECT (SELECT sqlserver_start_time FROM sys.dm_os_sys_info) AS SqlServerStart,
       OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.type_desc, i.has_filter,
       ISNULL(us.user_seeks, 0) AS UserSeeks, ISNULL(us.user_scans, 0) AS UserScans,
       ISNULL(us.user_lookups, 0) AS UserLookups, ISNULL(us.user_updates, 0) AS UserUpdates,
       us.last_user_seek, us.last_user_scan
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE OBJECT_SCHEMA_NAME(i.object_id) = N'dbo' AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1 AND i.index_id > 0
ORDER BY TableName, i.index_id;
PRINT N'== M4. Index phụ CHƯA quan sát thấy lượt đọc nào trong phiên lab (ứng viên xem xét bỏ) ==';
SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.filter_definition,
       ISNULL(us.user_updates, 0) AS UserUpdates, ps.used_page_count
FROM sys.indexes i
JOIN sys.dm_db_partition_stats ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE OBJECT_SCHEMA_NAME(i.object_id) = N'dbo' AND i.index_id > 1 AND i.is_primary_key = 0
  AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0;
GO
/* ---------------------------------------------------------------------
   M5. Fragmentation (SAMPLED) kèm page_count — index < ~1.000 trang thường
       không đáng để REBUILD/REORGANIZE dù % phân mảnh cao.
   --------------------------------------------------------------------- */
PRINT N'== M5. Fragmentation ==';
SELECT OBJECT_NAME(ps.object_id) AS TableName, i.name AS IndexName, ps.index_type_desc, ps.page_count,
       CAST(ps.avg_fragmentation_in_percent AS DECIMAL(6,2)) AS AvgFragmentationPct,
       CAST(ps.avg_page_space_used_in_percent AS DECIMAL(6,2)) AS AvgPageSpaceUsedPct,
       ps.fragment_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'SAMPLED') ps
JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE OBJECT_SCHEMA_NAME(ps.object_id) = N'dbo' AND ps.alloc_unit_type_desc = N'IN_ROW_DATA'
ORDER BY TableName, ps.index_id;
GO
