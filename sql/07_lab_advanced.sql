/* =====================================================================
   07_lab_advanced.sql — Lab 4: filtered index (Ca 3 – S2), phân trang keyset
   vs OFFSET, EXISTS/IN/JOIN, window function vs subquery tương quan,
   nonclustered columnstore, indexed view, cursor -> set-based.
   Mỗi phần bắt đầu từ lab.usp_ResetLab rồi tạo ĐÚNG bộ index công bố ở đầu phần.
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
/* =====================================================================
   P1. Ca 3 — S2 filtered index cho Status = 'Pending' (tiếp nối CA3-IDX của Lab 04)
   Đầu vào: chỉ PK + IXReliefRequestPending (KHÔNG có index báo cáo)
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXReliefRequestPending
    ON dbo.ReliefRequest (RegionID, CreatedAt) INCLUDE (ItemID, RequestedQty)
    WHERE Status = 'Pending';
GO
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16 NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S2 filtered IXReliefRequestPending | R1',  'Q01', @R1;
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S2 filtered IXReliefRequestPending | R16', 'Q01', @R16;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R1',  'S2 filtered IXReliefRequestPending | R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R16', 'S2 filtered IXReliefRequestPending | R16', @OrderMatters = 1;
-- Cùng câu hỏi nhưng Status truyền bằng THAM SỐ: optimizer không thể chứng minh @Status = 'Pending'
-- tại lúc biên dịch nên không được dùng filtered index (giới hạn cần biết khi viết ứng dụng).
EXEC lab.usp_Measure 'CA3-IDX', 'S2 filtered, Status as @param | R1',
     @ParamDef = N'@RegionID INT, @Status VARCHAR(20), @From DATETIME2, @To DATETIME2',
     @ParamVals = N'@RegionID = 1, @Status = ''Pending'', @From = ''2025-03-01'', @To = ''2025-09-01''', @Stmt = N'
SELECT RequestID, ItemID, RequestedQty, CreatedAt
FROM dbo.ReliefRequest
WHERE RegionID = @RegionID AND Status = @Status
  AND CreatedAt >= @From AND CreatedAt < @To
ORDER BY CreatedAt, RequestID;';
EXEC lab.usp_CheckSame 'CA3-IDX', 'S2 filtered IXReliefRequestPending | R1', 'S2 filtered, Status as @param | R1', @OrderMatters = 1;
GO
PRINT N'== P1. Kích thước: filtered index so với index của báo cáo ==';
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
SELECT i.name AS IndexName, i.has_filter, i.filter_definition, ps.row_count, ps.used_page_count
FROM sys.dm_db_partition_stats ps JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id = OBJECT_ID(N'dbo.ReliefRequest') ORDER BY i.index_id;
-- Khi có CẢ HAI index: optimizer chọn index nào cho Q01?
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S3 both report + filtered | R1', 'Q01', @R1;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R1', 'S3 both report + filtered | R1', @OrderMatters = 1;
GO
/* =====================================================================
   P2. Demo phân trang lịch sử xuất: OFFSET vs keyset
   Đầu vào: PK + IXDispatchOrderWarehouseItem (index của báo cáo).
   Kho 1, vật phẩm 14 (357 lượt xuất). Thứ tự duy nhất: DispatchedAt DESC, DispatchID DESC.
   Trang k (k >= 2) bằng keyset dùng KHÓA CUỐI của trang k-1 làm mốc.
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseItem
    ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID);
GO
DECLARE @page INT, @skip INT, @lastAt DATETIME2, @lastID INT, @pvO NVARCHAR(200), @pvK NVARCHAR(300), @vO NVARCHAR(120), @vK NVARCHAR(120);
DECLARE pages CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM (VALUES (2), (7)) p(v);
OPEN pages; FETCH NEXT FROM pages INTO @page;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @skip = (@page - 1) * 50;
    -- khóa cuối của trang trước = dòng thứ @skip theo đúng thứ tự
    SELECT @lastAt = DispatchedAt, @lastID = DispatchID
    FROM dbo.DispatchOrder WHERE WarehouseID = 1 AND ItemID = 14
    ORDER BY DispatchedAt DESC, DispatchID DESC
    OFFSET @skip - 1 ROWS FETCH NEXT 1 ROW ONLY;
    SELECT @page AS Page, @skip AS SkipRows, @lastAt AS PrevPageLastDispatchedAt, @lastID AS PrevPageLastDispatchID;
    SET @pvO = CONCAT(N'@WarehouseID = 1, @ItemID = 14, @Skip = ', @skip);
    SET @pvK = CONCAT(N'@WarehouseID = 1, @ItemID = 14, @LastAt = ''', CONVERT(NVARCHAR(30), @lastAt, 126), N''', @LastID = ', @lastID);
    SET @vO = CONCAT(N'OFFSET page ', @page);
    SET @vK = CONCAT(N'keyset page ', @page);
    EXEC lab.usp_MeasureQ 'PAGE-DISPATCH', @vO, 'Q09', @pvO;
    EXEC lab.usp_MeasureQ 'PAGE-DISPATCH', @vK, 'Q10', @pvK;
    EXEC lab.usp_CheckSame 'PAGE-DISPATCH', @vO, @vK, @OrderMatters = 1;
    FETCH NEXT FROM pages INTO @page;
END;
CLOSE pages; DEALLOCATE pages;
GO
/* P2b. Cùng kỹ thuật trên tập lớn hơn: AuditLog của kho 5 (3.376 dòng), trang 60 (bỏ qua 2.950 dòng)
   Đầu vào thêm: IXAuditLogWarehouseTime (WarehouseID, LoggedAt) INCLUDE (ItemID, ActionType, DeltaQty) */
CREATE NONCLUSTERED INDEX IXAuditLogWarehouseTime
    ON dbo.AuditLog (WarehouseID, LoggedAt) INCLUDE (ItemID, ActionType, DeltaQty);
GO
DECLARE @lastAt DATETIME2, @lastID BIGINT;
SELECT @lastAt = LoggedAt, @lastID = LogID FROM dbo.AuditLog WHERE WarehouseID = 5
ORDER BY LoggedAt DESC, LogID DESC OFFSET 2949 ROWS FETCH NEXT 1 ROW ONLY;
SELECT 60 AS Page, 2950 AS SkipRows, @lastAt AS PrevPageLastLoggedAt, @lastID AS PrevPageLastLogID;
DECLARE @pvK NVARCHAR(300) = CONCAT(N'@WarehouseID = 5, @LastAt = ''', CONVERT(NVARCHAR(30), @lastAt, 126), N''', @LastID = ', @lastID);
EXEC lab.usp_MeasureQ 'PAGE-AUDIT', 'OFFSET page 60', 'Q08', N'@WarehouseID = 5, @Skip = 2950';
EXEC lab.usp_Measure  'PAGE-AUDIT', 'keyset page 60', @ParamDef = N'@WarehouseID INT, @LastAt DATETIME2, @LastID BIGINT', @ParamVals = @pvK, @Stmt = N'
SELECT TOP (50) LogID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE WarehouseID = @WarehouseID
  AND (LoggedAt < @LastAt OR (LoggedAt = @LastAt AND LogID < @LastID))
ORDER BY LoggedAt DESC, LogID DESC;';
EXEC lab.usp_CheckSame 'PAGE-AUDIT', 'OFFSET page 60', 'keyset page 60', @OrderMatters = 1;
GO
/* =====================================================================
   P3. EXISTS / IN / JOIN — "Nhà tài trợ nào đã tài trợ hàng xuất từ kho @W?"
   Đầu vào: PK + IXDispatchOrderWarehouseDonor (WarehouseID, DonorID)
   JOIN cần DISTINCT mới cùng nghĩa (mỗi nhà tài trợ có nhiều lượt xuất).
   Câu phủ định: NOT IN gặp DonorID NULL trong subquery -> không trả dòng nào.
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseDonor ON dbo.DispatchOrder (WarehouseID, DonorID);
GO
DECLARE @pd NVARCHAR(50) = N'@WarehouseID INT', @pv NVARCHAR(50) = N'@WarehouseID = 7';
EXEC lab.usp_Measure 'SEMIJOIN', 'a EXISTS', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
WHERE EXISTS (SELECT 1 FROM dbo.DispatchOrder AS o WHERE o.DonorID = d.DonorID AND o.WarehouseID = @WarehouseID)
ORDER BY d.DonorID;';
EXEC lab.usp_Measure 'SEMIJOIN', 'b IN', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
WHERE d.DonorID IN (SELECT o.DonorID FROM dbo.DispatchOrder AS o WHERE o.WarehouseID = @WarehouseID)
ORDER BY d.DonorID;';
EXEC lab.usp_Measure 'SEMIJOIN', 'c JOIN + DISTINCT', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT DISTINCT d.DonorID, d.DonorName FROM dbo.Donor AS d
JOIN dbo.DispatchOrder AS o ON o.DonorID = d.DonorID
WHERE o.WarehouseID = @WarehouseID
ORDER BY d.DonorID;';
EXEC lab.usp_Measure 'SEMIJOIN', 'd JOIN without DISTINCT (sai nghia)', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
JOIN dbo.DispatchOrder AS o ON o.DonorID = d.DonorID
WHERE o.WarehouseID = @WarehouseID
ORDER BY d.DonorID;';
EXEC lab.usp_CheckSame 'SEMIJOIN', 'a EXISTS', 'b IN', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'SEMIJOIN', 'a EXISTS', 'c JOIN + DISTINCT', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'SEMIJOIN', 'a EXISTS', 'd JOIN without DISTINCT (sai nghia)', @Expected = 'DIFFERENT';
EXEC lab.usp_Measure 'ANTIJOIN', 'a NOT EXISTS', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
WHERE NOT EXISTS (SELECT 1 FROM dbo.DispatchOrder AS o WHERE o.DonorID = d.DonorID AND o.WarehouseID = @WarehouseID)
ORDER BY d.DonorID;';
EXEC lab.usp_Measure 'ANTIJOIN', 'b NOT IN (subquery co NULL)', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
WHERE d.DonorID NOT IN (SELECT o.DonorID FROM dbo.DispatchOrder AS o WHERE o.WarehouseID = @WarehouseID)
ORDER BY d.DonorID;';
EXEC lab.usp_Measure 'ANTIJOIN', 'c NOT IN + IS NOT NULL', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT d.DonorID, d.DonorName FROM dbo.Donor AS d
WHERE d.DonorID NOT IN (SELECT o.DonorID FROM dbo.DispatchOrder AS o
                        WHERE o.WarehouseID = @WarehouseID AND o.DonorID IS NOT NULL)
ORDER BY d.DonorID;';
EXEC lab.usp_CheckSame 'ANTIJOIN', 'a NOT EXISTS', 'b NOT IN (subquery co NULL)', @Expected = 'DIFFERENT';
EXEC lab.usp_CheckSame 'ANTIJOIN', 'a NOT EXISTS', 'c NOT IN + IS NOT NULL', @OrderMatters = 1;
GO
/* =====================================================================
   P4. Window function vs subquery tương quan
   "Lượt xuất gần nhất của mỗi yêu cầu thuộc vùng @R" (giữ cả trường hợp đồng thời điểm)
   Đầu vào: PK + IXReliefRequestRegionStatus (báo cáo)
            + IXDispatchOrderRequestTime (RequestID, DispatchedAt) INCLUDE (WarehouseID, DispatchedQty)
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
CREATE NONCLUSTERED INDEX IXDispatchOrderRequestTime
    ON dbo.DispatchOrder (RequestID, DispatchedAt) INCLUDE (WarehouseID, DispatchedQty);
GO
DECLARE @pd NVARCHAR(50) = N'@RegionID INT', @pv NVARCHAR(50) = N'@RegionID = 4';
EXEC lab.usp_Measure 'WINDOW', 'a correlated MAX subquery | R4', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT r.RequestID, d.DispatchID, d.WarehouseID, d.DispatchedQty, d.DispatchedAt
FROM dbo.ReliefRequest AS r
JOIN dbo.DispatchOrder AS d ON d.RequestID = r.RequestID
WHERE r.RegionID = @RegionID
  AND d.DispatchedAt = (SELECT MAX(d2.DispatchedAt) FROM dbo.DispatchOrder AS d2 WHERE d2.RequestID = r.RequestID)
ORDER BY r.RequestID, d.DispatchID;';
EXEC lab.usp_Measure 'WINDOW', 'b MAX() OVER (PARTITION BY) | R4', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT RequestID, DispatchID, WarehouseID, DispatchedQty, DispatchedAt
FROM (SELECT r.RequestID, d.DispatchID, d.WarehouseID, d.DispatchedQty, d.DispatchedAt,
             MAX(d.DispatchedAt) OVER (PARTITION BY d.RequestID) AS LastAt
      FROM dbo.ReliefRequest AS r
      JOIN dbo.DispatchOrder AS d ON d.RequestID = r.RequestID
      WHERE r.RegionID = @RegionID) AS x
WHERE DispatchedAt = LastAt
ORDER BY RequestID, DispatchID;';
EXEC lab.usp_Measure 'WINDOW', 'c GROUP BY MAX + JOIN | R4', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT r.RequestID, d.DispatchID, d.WarehouseID, d.DispatchedQty, d.DispatchedAt
FROM dbo.ReliefRequest AS r
JOIN (SELECT RequestID, MAX(DispatchedAt) AS LastAt FROM dbo.DispatchOrder GROUP BY RequestID) AS m
     ON m.RequestID = r.RequestID
JOIN dbo.DispatchOrder AS d ON d.RequestID = m.RequestID AND d.DispatchedAt = m.LastAt
WHERE r.RegionID = @RegionID
ORDER BY r.RequestID, d.DispatchID;';
EXEC lab.usp_CheckSame 'WINDOW', 'a correlated MAX subquery | R4', 'b MAX() OVER (PARTITION BY) | R4', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'WINDOW', 'a correlated MAX subquery | R4', 'c GROUP BY MAX + JOIN | R4', @OrderMatters = 1;
GO
/* =====================================================================
   P5. Nonclustered columnstore cho báo cáo tổng hợp DispatchOrder và AuditLog
   Trước: chỉ PK (rowstore). Sau: thêm NCCI trên đúng các cột báo cáo dùng.
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
DECLARE @qD NVARCHAR(MAX) = N'
SELECT WarehouseID, DATEFROMPARTS(YEAR(DispatchedAt), MONTH(DispatchedAt), 1) AS MonthStart,
       COUNT_BIG(*) AS Dispatches, SUM(CAST(DispatchedQty AS BIGINT)) AS TotalQty
FROM dbo.DispatchOrder
GROUP BY WarehouseID, DATEFROMPARTS(YEAR(DispatchedAt), MONTH(DispatchedAt), 1)
ORDER BY WarehouseID, MonthStart;';
DECLARE @qA NVARCHAR(MAX) = N'
SELECT ActionType, DATEFROMPARTS(YEAR(LoggedAt), MONTH(LoggedAt), 1) AS MonthStart,
       COUNT_BIG(*) AS Entries, SUM(CAST(DeltaQty AS BIGINT)) AS NetDelta
FROM dbo.AuditLog
GROUP BY ActionType, DATEFROMPARTS(YEAR(LoggedAt), MONTH(LoggedAt), 1)
ORDER BY ActionType, MonthStart;';
EXEC lab.usp_Measure 'NCCI', 'DispatchOrder monthly | rowstore PK only', @qD;
EXEC lab.usp_Measure 'NCCI', 'AuditLog monthly | rowstore PK only', @qA;
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCIDispatchOrder ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedQty, DispatchedAt);
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCIAuditLog     ON dbo.AuditLog (WarehouseID, ActionType, DeltaQty, LoggedAt);
EXEC lab.usp_Measure 'NCCI', 'DispatchOrder monthly | + NCCI', @qD;
EXEC lab.usp_Measure 'NCCI', 'AuditLog monthly | + NCCI', @qA;
EXEC lab.usp_CheckSame 'NCCI', 'DispatchOrder monthly | rowstore PK only', 'DispatchOrder monthly | + NCCI', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'NCCI', 'AuditLog monthly | rowstore PK only', 'AuditLog monthly | + NCCI', @OrderMatters = 1;
PRINT N'== P5. Rowgroup của columnstore và kích thước so với clustered rowstore ==';
SELECT OBJECT_NAME(object_id) AS TableName, row_group_id, state_desc, total_rows, size_in_bytes
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id IN (OBJECT_ID(N'dbo.DispatchOrder'), OBJECT_ID(N'dbo.AuditLog'));
SELECT OBJECT_NAME(ps.object_id) AS TableName, i.name AS IndexName, i.type_desc, ps.used_page_count, ps.lob_used_page_count
FROM sys.dm_db_partition_stats ps JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id IN (OBJECT_ID(N'dbo.DispatchOrder'), OBJECT_ID(N'dbo.AuditLog')) ORDER BY TableName, i.index_id;
GO
/* =====================================================================
   P6. Indexed view tổng hợp tồn kho khả dụng theo (RegionID, ItemID) — phần "stock" của Ca 2
   Đầu vào: PK + IXDispatchOrderRequest (index của Ca 1, cố định cho cả trước/sau)
   Trước/sau chỉ khác: có hay không exp.vInventoryByRegionItem (unique clustered index).
   Truy vấn KHÔNG đổi chữ (không dùng NOEXPAND) — dựa vào view matching của bản Developer/Enterprise.
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXDispatchOrderRequest ON dbo.DispatchOrder (RequestID) INCLUDE (DispatchedQty);
GO
DECLARE @qStock NVARCHAR(MAX) = N'
SELECT w.RegionID, inv.ItemID, SUM(CAST(inv.Quantity - inv.ReservedQty AS BIGINT)) AS LocalAvailable
FROM dbo.Inventory AS inv
JOIN dbo.Warehouse AS w ON w.WarehouseID = inv.WarehouseID
GROUP BY w.RegionID, inv.ItemID
ORDER BY w.RegionID, inv.ItemID;';
EXEC lab.usp_Measure  'IVIEW', 'stock by region-item | no view', @qStock;
EXEC lab.usp_MeasureQ 'IVIEW', 'Q04 Ca 2 | no view', 'Q04';
EXEC (N'CREATE VIEW exp.vInventoryByRegionItem WITH SCHEMABINDING AS
SELECT w.RegionID, inv.ItemID,
       SUM(CAST(inv.Quantity - inv.ReservedQty AS BIGINT)) AS LocalAvailable,
       COUNT_BIG(*) AS InventoryRows
FROM dbo.Inventory AS inv
JOIN dbo.Warehouse AS w ON w.WarehouseID = inv.WarehouseID
GROUP BY w.RegionID, inv.ItemID;');
CREATE UNIQUE CLUSTERED INDEX UCXvInventoryByRegionItem ON exp.vInventoryByRegionItem (RegionID, ItemID);
EXEC lab.usp_Measure  'IVIEW', 'stock by region-item | indexed view', @qStock;
EXEC lab.usp_MeasureQ 'IVIEW', 'Q04 Ca 2 | indexed view', 'Q04';
EXEC lab.usp_CheckSame 'IVIEW', 'stock by region-item | no view', 'stock by region-item | indexed view', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'IVIEW', 'Q04 Ca 2 | no view', 'Q04 Ca 2 | indexed view', @OrderMatters = 1;
SELECT COUNT_BIG(*) AS ViewRows FROM exp.vInventoryByRegionItem WITH (NOEXPAND);
GO
/* =====================================================================
   P7. Viết lại cursor của uspReportUrgentRegions (Mã nguồn 1.3) thành set-based
   Đầu vào: PK + IXReliefRequestRegionStatus. Giữ: cộng theo từng vùng và từng vật phẩm;
   vùng khẩn cấp chưa có yêu cầu Pending vẫn có 1 dòng "chưa có yêu cầu chờ".
   Bản gốc in bằng PRINT (không có result set). Để kiểm tra tương đương, bản
   exp.uspReportUrgentRegions_CursorCapture chạy ĐÚNG vòng cursor đó nhưng gom
   các dòng vào biến bảng rồi trả ra; so với bản set-based (không xét thứ tự vì
   cursor gốc không có ORDER BY).
   ===================================================================== */
EXEC lab.usp_ResetLab;
GO
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
GO
CREATE OR ALTER PROCEDURE exp.uspReportUrgentRegions_SetBased @MinSeverity TINYINT = 4
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Region WHERE SeverityLevel >= @MinSeverity)
    BEGIN PRINT N'Khong co khu vuc nao dat nguong khan cap.'; RETURN; END;
    WITH agg AS (
        SELECT r.RegionID, r.RegionName,
               CASE WHEN r.SeverityLevel = 5 THEN N'Bao dong do' ELSE N'Muc cao' END AS Tier,
               it.ItemID, it.Unit, ISNULL(SUM(CONVERT(BIGINT, rq.RequestedQty)), 0) AS PendingQty
        FROM dbo.Region r
        LEFT JOIN dbo.ReliefRequest rq ON r.RegionID = rq.RegionID AND rq.Status = 'Pending'
        LEFT JOIN dbo.Item AS it ON it.ItemID = rq.ItemID
        WHERE r.SeverityLevel >= @MinSeverity
        GROUP BY r.RegionID, r.RegionName, r.SeverityLevel, it.ItemID, it.Unit)
    SELECT RegionID, ItemID, PendingQty,
           CASE WHEN ItemID IS NULL
                THEN CONCAT(RegionName, N' [', Tier, N']: chưa có yêu cầu chờ.')
                ELSE CONCAT(RegionName, N' [', Tier, N'], vật phẩm ', ItemID, N': ', PendingQty, N' ', Unit) END AS Line
    FROM agg
    ORDER BY RegionID, ItemID;
END;
GO
CREATE OR ALTER PROCEDURE exp.uspReportUrgentRegions_CursorCapture @MinSeverity TINYINT = 4
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @out TABLE (RegionID INT, ItemID INT, PendingQty BIGINT, Line NVARCHAR(400));
    IF NOT EXISTS (SELECT 1 FROM dbo.Region WHERE SeverityLevel >= @MinSeverity)
    BEGIN PRINT N'Khong co khu vuc nao dat nguong khan cap.'; RETURN; END;
    DECLARE @RegionID INT, @RegionName NVARCHAR(100), @Tier NVARCHAR(30);
    DECLARE @ItemID INT, @Unit NVARCHAR(20), @PendingQty BIGINT;
    DECLARE curUrgent CURSOR LOCAL FAST_FORWARD FOR
        SELECT r.RegionID, r.RegionName,
               CASE WHEN r.SeverityLevel = 5 THEN N'Bao dong do' ELSE N'Muc cao' END,
               it.ItemID, it.Unit, ISNULL(SUM(CONVERT(BIGINT, rq.RequestedQty)), 0)
        FROM dbo.Region r
        LEFT JOIN dbo.ReliefRequest rq ON r.RegionID = rq.RegionID AND rq.Status = 'Pending'
        LEFT JOIN dbo.Item AS it ON it.ItemID = rq.ItemID
        WHERE r.SeverityLevel >= @MinSeverity
        GROUP BY r.RegionID, r.RegionName, r.SeverityLevel, it.ItemID, it.Unit;
    OPEN curUrgent;
    FETCH NEXT FROM curUrgent INTO @RegionID, @RegionName, @Tier, @ItemID, @Unit, @PendingQty;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT @out VALUES (@RegionID, @ItemID, @PendingQty,
            CASE WHEN @ItemID IS NULL THEN CONCAT(@RegionName, N' [', @Tier, N']: chưa có yêu cầu chờ.')
                 ELSE CONCAT(@RegionName, N' [', @Tier, N'], vật phẩm ', @ItemID, N': ', @PendingQty, N' ', @Unit) END);
        FETCH NEXT FROM curUrgent INTO @RegionID, @RegionName, @Tier, @ItemID, @Unit, @PendingQty;
    END;
    CLOSE curUrgent; DEALLOCATE curUrgent;
    SELECT RegionID, ItemID, PendingQty, Line FROM @out;
END;
GO
DECLARE @pd NVARCHAR(50) = N'@MinSeverity TINYINT', @pv NVARCHAR(50) = N'@MinSeverity = 4';
EXEC lab.usp_MeasureQ 'CURSOR', 'a cursor + PRINT (Ma nguon 1.3)', 'Q11', @pv;
EXEC lab.usp_Measure  'CURSOR', 'b set-based', N'EXEC exp.uspReportUrgentRegions_SetBased @MinSeverity = @MinSeverity;', @pd, @pv;
EXEC lab.usp_Measure  'CURSOR', 'c cursor capture (kiem tra nghia)', N'EXEC exp.uspReportUrgentRegions_CursorCapture @MinSeverity = @MinSeverity;', @pd, @pv;
EXEC lab.usp_CheckSame 'CURSOR', 'b set-based', 'c cursor capture (kiem tra nghia)', @OrderMatters = 0;
GO
PRINT N'== P7. Kết quả set-based: số dòng theo vùng và dòng "chưa có yêu cầu chờ" ==';
CREATE TABLE #rep (RegionID INT, ItemID INT, PendingQty BIGINT, Line NVARCHAR(400));
INSERT #rep EXEC exp.uspReportUrgentRegions_SetBased @MinSeverity = 4;
SELECT RegionID, COUNT(*) AS Lines, SUM(PendingQty) AS PendingQty, SUM(CASE WHEN ItemID IS NULL THEN 1 ELSE 0 END) AS NoPendingLine
FROM #rep GROUP BY RegionID ORDER BY RegionID;
SELECT Line FROM #rep WHERE ItemID IS NULL;
IF NOT EXISTS (SELECT 1 FROM #rep WHERE RegionID = 20 AND ItemID IS NULL)
    THROW 50050, N'Thiếu dòng "chưa có yêu cầu chờ" cho vùng 20.', 1;
-- Đối chiếu tổng Pending từng vùng với tính trực tiếp
IF EXISTS (SELECT r.RegionID FROM dbo.Region r
           WHERE r.SeverityLevel >= 4
             AND ISNULL((SELECT SUM(CAST(q.RequestedQty AS BIGINT)) FROM dbo.ReliefRequest q WHERE q.RegionID = r.RegionID AND q.Status = 'Pending'), 0)
                 <> (SELECT SUM(PendingQty) FROM #rep WHERE RegionID = r.RegionID))
    THROW 50051, N'Tổng Pending theo vùng của bản set-based lệch với tính trực tiếp.', 1;
DROP TABLE #rep;
GO
PRINT N'== Tổng hợp Lab 07 (pass hiện tại) ==';
SELECT m.CaseID, m.Variant, m.RowsReturned, m.MedianReads, m.MinReads, m.MaxReads, m.MedianCpuMs, m.MedianElapsedMs
FROM lab.vMeasureSummary m
WHERE m.PassNo = (SELECT PassNo FROM lab.RunContext)
  AND m.CaseID IN ('CA3-IDX','PAGE-DISPATCH','PAGE-AUDIT','SEMIJOIN','ANTIJOIN','WINDOW','NCCI','IVIEW','CURSOR')
ORDER BY m.CaseID, m.Variant;
SELECT CaseID, VariantA, VariantB, RowsA, RowsB, BagEqual, OrderEqual, Expected
FROM lab.Equivalence WHERE PassNo = (SELECT PassNo FROM lab.RunContext)
  AND CaseID IN ('CA3-IDX','PAGE-DISPATCH','PAGE-AUDIT','SEMIJOIN','ANTIJOIN','WINDOW','NCCI','IVIEW','CURSOR')
ORDER BY EquivalenceID;
GO
