/* =====================================================================
   06_lab_stats_sniffing.sql — Lab 3: statistics, ước lượng, parameter
   sniffing và PSP (Parameter Sensitive Plan optimization, compat 170).
   Bộ index CỐ ĐỊNH cho cả lab (công bố):
     IXReliefRequestRegionStatusNarrow ON ReliefRequest (RegionID, Status, CreatedAt)
     — KHÔNG INCLUDE. Ở Lab 04 index này cho hai plan khác nhau:
       R16 (ít dòng) -> Index Seek + Key Lookup; R1 (nhiều dòng) -> Clustered Index Scan.
     (Với index covering của báo cáo, mọi vùng đều dùng chung một plan Seek
      tốt nên không có hiện tượng sniffing để quan sát.)
   Truy vấn: Q01 (Ca 3) đóng gói trong thủ tục exp.uspPendingByRegion.
   Trong lab này usp_Measure chạy với @FreshCompile = 0 để GIỮ cached plan
   giữa các lần gọi; việc biên dịch lại chỉ do sp_recompile trên ĐÚNG thủ tục.
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatusNarrow
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt);   -- tạo index => statistics FULLSCAN trên khóa
GO
/* ---------------------------------------------------------------------
   A. Histogram cột đầu RegionID
   --------------------------------------------------------------------- */
PRINT N'== A1. DBCC SHOW_STATISTICS — header ==';
DBCC SHOW_STATISTICS ('dbo.ReliefRequest', IXReliefRequestRegionStatusNarrow) WITH STAT_HEADER, NO_INFOMSGS;
PRINT N'== A2. DBCC SHOW_STATISTICS — density vector ==';
DBCC SHOW_STATISTICS ('dbo.ReliefRequest', IXReliefRequestRegionStatusNarrow) WITH DENSITY_VECTOR, NO_INFOMSGS;
PRINT N'== A3. DBCC SHOW_STATISTICS — histogram RegionID ==';
DBCC SHOW_STATISTICS ('dbo.ReliefRequest', IXReliefRequestRegionStatusNarrow) WITH HISTOGRAM, NO_INFOMSGS;
PRINT N'== A4. Đối chiếu EQ_ROWS của histogram với số đếm thật (R1, R16) ==';
SELECT h.range_high_key AS RegionID, h.equal_rows AS Histogram_EQ_ROWS,
       (SELECT COUNT(*) FROM dbo.ReliefRequest r WHERE r.RegionID = CAST(h.range_high_key AS INT)) AS ActualRows,
       (SELECT COUNT(*) FROM dbo.ReliefRequest r WHERE r.RegionID = CAST(h.range_high_key AS INT) AND r.Status = 'Pending') AS ActualPending,
       (SELECT COUNT(*) FROM dbo.ReliefRequest r WHERE r.RegionID = CAST(h.range_high_key AS INT) AND r.Status = 'Pending'
              AND r.CreatedAt >= '2025-03-01' AND r.CreatedAt < '2025-09-01') AS ActualPendingInRange
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_histogram(s.object_id, s.stats_id) h
WHERE s.object_id = OBJECT_ID(N'dbo.ReliefRequest') AND s.name = N'IXReliefRequestRegionStatusNarrow'
  AND CAST(h.range_high_key AS INT) IN (1, 16);
GO
/* ---------------------------------------------------------------------
   B. Estimated vs actual khi mỗi tham số được biên dịch riêng (FreshCompile)
      -> plan: evidence/plans/pass<N>/STATS-EST__*.sqlplan
   --------------------------------------------------------------------- */
EXEC lab.usp_MeasureQ 'STATS-EST', 'own compile | R1',  'Q01', N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'STATS-EST', 'own compile | R16', 'Q01', N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
GO
/* ---------------------------------------------------------------------
   C. Parameter sniffing với PSP TẮT (database lab)
   --------------------------------------------------------------------- */
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
GO
CREATE OR ALTER PROCEDURE exp.uspPendingByRegion
    @RegionID INT, @From DATETIME2, @To DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequestID, ItemID, RequestedQty, CreatedAt
    FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID AND Status = 'Pending'
      AND CreatedAt >= @From AND CreatedAt < @To
    ORDER BY CreatedAt, RequestID;
END;
GO
DECLARE @stmt NVARCHAR(200) = N'EXEC exp.uspPendingByRegion @RegionID = @RegionID, @From = @From, @To = @To;';
DECLARE @pd   NVARCHAR(200) = N'@RegionID INT, @From DATETIME2, @To DATETIME2';
DECLARE @R1   NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16  NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
-- C1: biên dịch với vùng ít (R16), rồi vùng nóng (R1) dùng lại cùng cached plan
EXEC sp_recompile N'exp.uspPendingByRegion';
EXEC lab.usp_Measure 'SNIFF-OFF', 'C1 compiled R16 -> run R16', @stmt, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-OFF', 'C1 compiled R16 -> run R1',  @stmt, @pd, @R1,  @FreshCompile = 0;
-- C2: đánh dấu riêng thủ tục để biên dịch lại, đảo thứ tự
EXEC sp_recompile N'exp.uspPendingByRegion';
EXEC lab.usp_Measure 'SNIFF-OFF', 'C2 compiled R1 -> run R1',   @stmt, @pd, @R1,  @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-OFF', 'C2 compiled R1 -> run R16',  @stmt, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_CheckSame 'SNIFF-OFF', 'C1 compiled R16 -> run R1',  'C2 compiled R1 -> run R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'SNIFF-OFF', 'C1 compiled R16 -> run R16', 'C2 compiled R1 -> run R16', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   D. Các cách xử lý (PSP vẫn TẮT để chỉ thay một yếu tố)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE exp.uspPendingByRegion_Recompile
    @RegionID INT, @From DATETIME2, @To DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequestID, ItemID, RequestedQty, CreatedAt
    FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID AND Status = 'Pending'
      AND CreatedAt >= @From AND CreatedAt < @To
    ORDER BY CreatedAt, RequestID
    OPTION (RECOMPILE);
END;
GO
CREATE OR ALTER PROCEDURE exp.uspPendingByRegion_OptimizeForHot
    @RegionID INT, @From DATETIME2, @To DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequestID, ItemID, RequestedQty, CreatedAt
    FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID AND Status = 'Pending'
      AND CreatedAt >= @From AND CreatedAt < @To
    ORDER BY CreatedAt, RequestID
    OPTION (OPTIMIZE FOR (@RegionID = 1));
END;
GO
CREATE OR ALTER PROCEDURE exp.uspPendingByRegion_OptimizeForUnknown
    @RegionID INT, @From DATETIME2, @To DATETIME2
AS
BEGIN
    SET NOCOUNT ON;
    SELECT RequestID, ItemID, RequestedQty, CreatedAt
    FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID AND Status = 'Pending'
      AND CreatedAt >= @From AND CreatedAt < @To
    ORDER BY CreatedAt, RequestID
    OPTION (OPTIMIZE FOR UNKNOWN);
END;
GO
DECLARE @pd   NVARCHAR(200) = N'@RegionID INT, @From DATETIME2, @To DATETIME2';
DECLARE @R1   NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16  NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @s NVARCHAR(200);
-- D1 OPTION (RECOMPILE): mỗi lần gọi biên dịch theo giá trị thật (trả giá CPU biên dịch)
SET @s = N'EXEC exp.uspPendingByRegion_Recompile @RegionID = @RegionID, @From = @From, @To = @To;';
EXEC lab.usp_Measure 'SNIFF-FIX', 'D1 OPTION(RECOMPILE) | R16', @s, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-FIX', 'D1 OPTION(RECOMPILE) | R1',  @s, @pd, @R1,  @FreshCompile = 0;
-- D2 OPTIMIZE FOR (@RegionID = 1): luôn dùng plan của vùng nóng
SET @s = N'EXEC exp.uspPendingByRegion_OptimizeForHot @RegionID = @RegionID, @From = @From, @To = @To;';
EXEC sp_recompile N'exp.uspPendingByRegion_OptimizeForHot';
EXEC lab.usp_Measure 'SNIFF-FIX', 'D2 OPTIMIZE FOR R1 | R16', @s, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-FIX', 'D2 OPTIMIZE FOR R1 | R1',  @s, @pd, @R1,  @FreshCompile = 0;
-- D3 OPTIMIZE FOR UNKNOWN: ước lượng theo mật độ trung bình, không theo giá trị
SET @s = N'EXEC exp.uspPendingByRegion_OptimizeForUnknown @RegionID = @RegionID, @From = @From, @To = @To;';
EXEC sp_recompile N'exp.uspPendingByRegion_OptimizeForUnknown';
EXEC lab.usp_Measure 'SNIFF-FIX', 'D3 OPTIMIZE FOR UNKNOWN | R16', @s, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-FIX', 'D3 OPTIMIZE FOR UNKNOWN | R1',  @s, @pd, @R1,  @FreshCompile = 0;
EXEC lab.usp_CheckSame 'SNIFF-FIX', 'D1 OPTION(RECOMPILE) | R1',  'D2 OPTIMIZE FOR R1 | R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'SNIFF-FIX', 'D1 OPTION(RECOMPILE) | R16', 'D3 OPTIMIZE FOR UNKNOWN | R16', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   E. PSP BẬT (compat 170): cùng thủ tục gốc, cùng thứ tự gọi như C1.
      Bằng chứng thu: Extended Events (PSP dùng / bị bỏ qua + lý do),
      Query Store query variant, và thuộc tính Dispatcher/QueryVariantID trong plan.
   --------------------------------------------------------------------- */
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'lab_psp') DROP EVENT SESSION lab_psp ON SERVER;
CREATE EVENT SESSION lab_psp ON SERVER
    ADD EVENT sqlserver.parameter_sensitive_plan_optimization_skipped_reason (
        ACTION (sqlserver.sql_text) WHERE (sqlserver.database_name = N'DisasterReliefDB')),
    ADD EVENT sqlserver.parameter_sensitive_plan_optimization (
        ACTION (sqlserver.sql_text) WHERE (sqlserver.database_name = N'DisasterReliefDB')),
    ADD EVENT sqlserver.multiplan_query_variant_plan_compiled (
        ACTION (sqlserver.sql_text) WHERE (sqlserver.database_name = N'DisasterReliefDB'))
    ADD TARGET package0.ring_buffer (SET max_events_limit = 1000)
    WITH (EVENT_RETENTION_MODE = NO_EVENT_LOSS, MAX_DISPATCH_LATENCY = 1 SECONDS);
ALTER EVENT SESSION lab_psp ON SERVER STATE = START;
GO
SELECT name, value FROM sys.database_scoped_configurations
WHERE name IN (N'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION', N'CE_FEEDBACK', N'PARAMETER_SNIFFING');
SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME();
GO
/* E0. Batch "sạch" — mỗi batch chỉ có một lệnh gọi, để sự kiện XE quy đúng về thủ tục
       (batch của harness có biến cục bộ, tự sinh lý do HasLocalVar/OutputOrModifiedParam). */
EXEC sp_recompile N'exp.uspPendingByRegion';
GO
EXEC exp.uspPendingByRegion @RegionID = 16, @From = '2025-03-01', @To = '2025-09-01';
GO
EXEC exp.uspPendingByRegion @RegionID = 1, @From = '2025-03-01', @To = '2025-09-01';
GO
/* Thủ tục chẩn đoán (không đo hiệu năng): bỏ hằng 'Pending' để xem điều kiện PSP còn thiếu gì
   - exp.uspPspProbe_RegionOnly : WHERE RegionID = @RegionID
   - exp.uspPspProbe_StatusParam: WHERE RegionID = @RegionID AND Status = @Status (tham số thay hằng) */
CREATE OR ALTER PROCEDURE exp.uspPspProbe_RegionOnly @RegionID INT AS
    SELECT RequestID, ItemID, RequestedQty, CreatedAt FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID ORDER BY CreatedAt, RequestID;
GO
CREATE OR ALTER PROCEDURE exp.uspPspProbe_StatusParam @RegionID INT, @Status VARCHAR(20) AS
    SELECT RequestID, ItemID, RequestedQty, CreatedAt FROM dbo.ReliefRequest
    WHERE RegionID = @RegionID AND Status = @Status ORDER BY CreatedAt, RequestID;
GO
EXEC exp.uspPspProbe_RegionOnly @RegionID = 16;
GO
EXEC exp.uspPspProbe_StatusParam @RegionID = 16, @Status = 'Pending';
GO
/* E1/E2. Đo như C1/C2 nhưng PSP BẬT */
DECLARE @stmt NVARCHAR(200) = N'EXEC exp.uspPendingByRegion @RegionID = @RegionID, @From = @From, @To = @To;';
DECLARE @pd   NVARCHAR(200) = N'@RegionID INT, @From DATETIME2, @To DATETIME2';
DECLARE @R1   NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16  NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC sp_recompile N'exp.uspPendingByRegion';
EXEC lab.usp_Measure 'SNIFF-PSP', 'E1 PSP ON compiled R16 -> run R16', @stmt, @pd, @R16, @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-PSP', 'E1 PSP ON compiled R16 -> run R1',  @stmt, @pd, @R1,  @FreshCompile = 0;
EXEC sp_recompile N'exp.uspPendingByRegion';
EXEC lab.usp_Measure 'SNIFF-PSP', 'E2 PSP ON compiled R1 -> run R1',   @stmt, @pd, @R1,  @FreshCompile = 0;
EXEC lab.usp_Measure 'SNIFF-PSP', 'E2 PSP ON compiled R1 -> run R16',  @stmt, @pd, @R16, @FreshCompile = 0;
GO
WAITFOR DELAY '00:00:02';   -- MAX_DISPATCH_LATENCY = 1 s
PRINT N'== E3. Extended Events: PSP được dùng hay bị bỏ qua (và lý do) ==';
DECLARE @x XML = (SELECT CAST(t.target_data AS XML)
                  FROM sys.dm_xe_session_targets t JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address
                  WHERE s.name = N'lab_psp' AND t.target_name = N'ring_buffer');
WITH ev AS (
    SELECT e.value('@name', 'NVARCHAR(80)') AS EventName,
           e.value('(data[@name="reason"]/text)[1]', 'NVARCHAR(60)') AS SkippedReason,
           e.value('(data[@name="query_variant_id"]/value)[1]', 'INT') AS QueryVariantID,
           e.value('(data[@name="predicate_count"]/value)[1]', 'INT') AS PredicateCount,
           LEFT(REPLACE(REPLACE(e.value('(action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)'), CHAR(13), ' '), CHAR(10), ' '), 90) AS SqlText
    FROM @x.nodes('/RingBufferTarget/event') n(e))
SELECT EventName, SkippedReason, QueryVariantID, PredicateCount, COUNT(*) AS Events, SqlText
FROM ev
WHERE SqlText LIKE N'EXEC exp.u%'     -- chỉ các batch sạch ở E0
GROUP BY EventName, SkippedReason, QueryVariantID, PredicateCount, SqlText
ORDER BY EventName, SkippedReason;
PRINT N'== E4. Query Store: query variant của thủ tục (rỗng = PSP không tạo variant) ==';
SELECT v.query_variant_query_id, v.parent_query_id, v.dispatcher_plan_id
FROM sys.query_store_query_variant v
JOIN sys.query_store_query q ON q.query_id = v.parent_query_id
WHERE q.object_id = OBJECT_ID(N'exp.uspPendingByRegion');
PRINT N'== E5. Query Store: các plan của thủ tục (plan_type 0 = Compiled, 1 = Dispatcher, 2 = Query variant) ==';
SELECT q.query_id, p.plan_id, p.plan_type, p.plan_type_desc, p.count_compiles
FROM sys.query_store_query q JOIN sys.query_store_plan p ON p.query_id = q.query_id
WHERE q.object_id = OBJECT_ID(N'exp.uspPendingByRegion')
ORDER BY q.query_id, p.plan_id;
GO
ALTER EVENT SESSION lab_psp ON SERVER STATE = STOP;
DROP EVENT SESSION lab_psp ON SERVER;
GO
PRINT N'== Tổng hợp Lab 06 (pass hiện tại) ==';
SELECT m.CaseID, m.Variant, m.RowsReturned, m.MedianReads, m.MinReads, m.MaxReads, m.MedianCpuMs, m.MedianElapsedMs
FROM lab.vMeasureSummary m
WHERE m.PassNo = (SELECT PassNo FROM lab.RunContext) AND (m.CaseID LIKE 'SNIFF-%' OR m.CaseID = 'STATS-EST')
ORDER BY m.CaseID, m.Variant;
SELECT CaseID, VariantA, VariantB, RowsA, RowsB, BagEqual, OrderEqual, Expected
FROM lab.Equivalence WHERE PassNo = (SELECT PassNo FROM lab.RunContext) AND CaseID LIKE 'SNIFF-%'
ORDER BY EquivalenceID;
GO
