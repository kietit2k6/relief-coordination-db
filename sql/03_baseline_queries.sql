/* =====================================================================
   03_baseline_queries.sql — truy vấn nghiệp vụ + kết quả Ca 1, Ca 2 + đo baseline
   Đầu vào: lab.usp_ResetLab => chỉ có clustered PK, statistics FULLSCAN,
            compat 170, PSP ON, cache ấm (mỗi biến thể làm nóng 1 lần, đo 5 lần).
   Tham số đo (chọn từ bảng K6/K7 của 02_seed_data.log):
     * Vùng nhiều Pending : RegionID = 1  (Quảng Trị, 657 Pending; 322 trong 01/03–31/08/2025)
     * Vùng ít Pending    : RegionID = 16 (Bắc Kạn,   13 Pending;   8 trong 01/03–31/08/2025)
     * Khoảng ngày Ca 3   : [2025-03-01, 2025-09-01)
     * Phân trang         : kho 1, vật phẩm 14 (357 lượt xuất — nhiều nhất)
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
/* ---------- Mã nguồn 1.3 của báo cáo (giữ nguyên nghiệp vụ, đặt trong dbo) ---------- */
CREATE OR ALTER PROCEDURE dbo.uspReportUrgentRegions @MinSeverity TINYINT = 4
AS
BEGIN
    SET NOCOUNT ON;
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
        IF @ItemID IS NULL
            PRINT CONCAT(@RegionName, N' [', @Tier, N']: chưa có yêu cầu chờ.');
        ELSE
            PRINT CONCAT(@RegionName, N' [', @Tier, N'], vật phẩm ', @ItemID,
                         N': ', @PendingQty, N' ', @Unit);
        FETCH NEXT FROM curUrgent INTO @RegionID, @RegionName, @Tier, @ItemID, @Unit, @PendingQty;
    END;
    CLOSE curUrgent; DEALLOCATE curUrgent;
END;
GO
/* =====================================================================
   Danh mục truy vấn nghiệp vụ (lab.Query) — các lab sau dùng lại đúng câu chữ này
   ===================================================================== */
DELETE lab.Query;
INSERT lab.Query (QueryID, Title, ParamDef, Stmt) VALUES
('Q01', N'Ca 3 — Yêu cầu Pending của một vùng trong khoảng ngày',
 N'@RegionID INT, @From DATETIME2, @To DATETIME2',
 N'SELECT RequestID, ItemID, RequestedQty, CreatedAt
FROM dbo.ReliefRequest
WHERE RegionID = @RegionID AND Status = ''Pending''
  AND CreatedAt >= @From AND CreatedAt < @To
ORDER BY CreatedAt, RequestID;'),

('Q02', N'Ca 1a — Yêu cầu nào đang chờ xử lý? (Status = Pending)',
 NULL,
 N'SELECT r.RequestID, r.RegionID, g.RegionName, r.ItemID, i.ItemName, i.Unit, r.RequestedQty, r.CreatedAt
FROM dbo.ReliefRequest AS r
JOIN dbo.Region AS g ON g.RegionID = r.RegionID
JOIN dbo.Item   AS i ON i.ItemID   = r.ItemID
WHERE r.Status = ''Pending''
ORDER BY r.CreatedAt, r.RequestID;'),

('Q03', N'Ca 1b — Còn bao nhiêu hàng phải cấp? (theo vùng, vật phẩm)',
 NULL,
 N'WITH d AS (            -- cộng lượng đã xuất theo từng yêu cầu TRƯỚC khi nối
    SELECT RequestID, SUM(CAST(DispatchedQty AS BIGINT)) AS DispatchedQty
    FROM dbo.DispatchOrder GROUP BY RequestID),
o AS (                  -- phần còn thiếu của từng yêu cầu còn hiệu lực (LEFT JOIN giữ yêu cầu chưa xuất)
    SELECT r.RequestID, r.RegionID, r.ItemID,
           r.RequestedQty - ISNULL(d.DispatchedQty, 0) AS Outstanding
    FROM dbo.ReliefRequest AS r
    LEFT JOIN d ON d.RequestID = r.RequestID
    WHERE r.Status IN (''Pending'', ''Approved'', ''PartiallyDispatched''))
SELECT RegionID, ItemID, COUNT_BIG(*) AS ActiveRequests, SUM(Outstanding) AS OutstandingQty
FROM o
GROUP BY RegionID, ItemID
ORDER BY RegionID, ItemID;'),

('Q04', N'Ca 2 — Vùng nào thiếu mặt hàng gì, thiếu bao nhiêu, kho tại chỗ đáp ứng được bao nhiêu?',
 NULL,
 N'WITH d AS (
    SELECT RequestID, SUM(CAST(DispatchedQty AS BIGINT)) AS DispatchedQty
    FROM dbo.DispatchOrder GROUP BY RequestID),
need AS (               -- nhu cầu còn phải cấp theo (RegionID, ItemID)
    SELECT r.RegionID, r.ItemID, SUM(r.RequestedQty - ISNULL(d.DispatchedQty, 0)) AS OutstandingQty
    FROM dbo.ReliefRequest AS r
    LEFT JOIN d ON d.RequestID = r.RequestID
    WHERE r.Status IN (''Pending'', ''Approved'', ''PartiallyDispatched'')
    GROUP BY r.RegionID, r.ItemID),
stock AS (              -- tồn khả dụng tại chỗ theo (RegionID, ItemID); kho thuộc vùng theo Warehouse.RegionID
    SELECT w.RegionID, inv.ItemID, SUM(CAST(inv.Quantity - inv.ReservedQty AS BIGINT)) AS LocalAvailable
    FROM dbo.Inventory AS inv
    JOIN dbo.Warehouse AS w ON w.WarehouseID = inv.WarehouseID
    GROUP BY w.RegionID, inv.ItemID),
m AS (
    SELECT n.RegionID, n.ItemID, n.OutstandingQty, ISNULL(s.LocalAvailable, 0) AS LocalAvailable,
           CASE WHEN ISNULL(s.LocalAvailable, 0) < n.OutstandingQty THEN ISNULL(s.LocalAvailable, 0)
                ELSE n.OutstandingQty END AS CanFulfil
    FROM need AS n
    LEFT JOIN stock AS s ON s.RegionID = n.RegionID AND s.ItemID = n.ItemID   -- giữ vùng không có dòng tồn
    WHERE n.OutstandingQty > 0)
SELECT m.RegionID, g.RegionName, m.ItemID, i.ItemName, i.Unit,
       m.OutstandingQty, m.LocalAvailable, m.CanFulfil,
       m.OutstandingQty - m.CanFulfil AS ShortfallAfterLocal
FROM m
JOIN dbo.Region AS g ON g.RegionID = m.RegionID
JOIN dbo.Item   AS i ON i.ItemID   = m.ItemID
ORDER BY ShortfallAfterLocal DESC, m.RegionID, m.ItemID;'),

('Q05', N'Tồn kho khả dụng của một vật phẩm tại các kho trong vùng',
 N'@RegionID INT, @ItemID INT',
 N'SELECT w.WarehouseID, w.WarehouseName, inv.Quantity, inv.ReservedQty,
       inv.Quantity - inv.ReservedQty AS Available
FROM dbo.Inventory AS inv
JOIN dbo.Warehouse AS w ON w.WarehouseID = inv.WarehouseID
WHERE w.RegionID = @RegionID AND inv.ItemID = @ItemID
ORDER BY w.WarehouseID;'),

('Q06', N'Lịch sử xuất theo kho, vật phẩm, khoảng ngày',
 N'@WarehouseID INT, @ItemID INT, @From DATETIME2, @To DATETIME2',
 N'SELECT DispatchID, RequestID, DispatchedQty, DispatchedAt
FROM dbo.DispatchOrder
WHERE WarehouseID = @WarehouseID AND ItemID = @ItemID
  AND DispatchedAt >= @From AND DispatchedAt < @To
ORDER BY DispatchedAt, DispatchID;'),

('Q07', N'Top 10 nhà tài trợ theo lượng hàng đã xuất trong khoảng ngày',
 N'@From DATETIME2, @To DATETIME2',
 N'SELECT TOP (10) d.DonorID, n.DonorName, n.DonorType,
       COUNT_BIG(*) AS Dispatches, SUM(CAST(d.DispatchedQty AS BIGINT)) AS TotalQty
FROM dbo.DispatchOrder AS d
JOIN dbo.Donor AS n ON n.DonorID = d.DonorID
WHERE d.DispatchedAt >= @From AND d.DispatchedAt < @To
GROUP BY d.DonorID, n.DonorName, n.DonorType
ORDER BY TotalQty DESC, d.DonorID;'),

('Q08', N'Phân trang nhật ký AuditLog của một kho (OFFSET)',
 N'@WarehouseID INT, @Skip INT',
 N'SELECT LogID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE WarehouseID = @WarehouseID
ORDER BY LoggedAt DESC, LogID DESC
OFFSET @Skip ROWS FETCH NEXT 50 ROWS ONLY;'),

('Q09', N'Demo phân trang lịch sử xuất — OFFSET',
 N'@WarehouseID INT, @ItemID INT, @Skip INT',
 N'SELECT DispatchID, RequestID, DispatchedQty, DispatchedAt
FROM dbo.DispatchOrder
WHERE WarehouseID = @WarehouseID AND ItemID = @ItemID
ORDER BY DispatchedAt DESC, DispatchID DESC
OFFSET @Skip ROWS FETCH NEXT 50 ROWS ONLY;'),

('Q10', N'Demo phân trang lịch sử xuất — keyset (mốc = khóa cuối trang trước)',
 N'@WarehouseID INT, @ItemID INT, @LastAt DATETIME2, @LastID INT',
 N'SELECT TOP (50) DispatchID, RequestID, DispatchedQty, DispatchedAt
FROM dbo.DispatchOrder
WHERE WarehouseID = @WarehouseID AND ItemID = @ItemID
  AND (DispatchedAt < @LastAt OR (DispatchedAt = @LastAt AND DispatchID < @LastID))
ORDER BY DispatchedAt DESC, DispatchID DESC;'),

('Q11', N'Báo cáo vùng khẩn cấp — thủ tục cursor của báo cáo (Mã nguồn 1.3)',
 N'@MinSeverity TINYINT',
 N'EXEC dbo.uspReportUrgentRegions @MinSeverity = @MinSeverity;');
SELECT QueryID, Title FROM lab.Query ORDER BY QueryID;
GO
/* =====================================================================
   KẾT QUẢ NGHIỆP VỤ Ca 1 và Ca 2 (chạy trước phần đo)
   ===================================================================== */
PRINT N'== B0. Trạng thái dùng trong dữ liệu seed và vai trò trong Ca 1 ==';
SELECT Status,
       CASE WHEN Status = 'Pending' THEN N'Ca 1a (đang chờ xử lý) + còn hiệu lực'
            WHEN Status IN ('Approved','PartiallyDispatched') THEN N'còn hiệu lực (Ca 1b, Ca 2)'
            ELSE N'không tính vào nhu cầu còn thiếu' END AS VaiTro,
       COUNT_BIG(*) AS Requests
FROM dbo.ReliefRequest GROUP BY Status ORDER BY Requests DESC;
GO
PRINT N'== B1. Kiểm tra dữ liệu: yêu cầu bị xuất vượt lượng yêu cầu (phải rỗng) ==';
WITH d AS (SELECT RequestID, SUM(CAST(DispatchedQty AS BIGINT)) AS DispatchedQty FROM dbo.DispatchOrder GROUP BY RequestID)
SELECT r.RequestID, r.RegionID, r.ItemID, r.Status, r.RequestedQty, d.DispatchedQty
FROM dbo.ReliefRequest r JOIN d ON d.RequestID = r.RequestID
WHERE d.DispatchedQty > r.RequestedQty;
IF @@ROWCOUNT > 0
    THROW 50030, N'Phát hiện yêu cầu bị xuất vượt lượng yêu cầu — cần nhóm đối chiếu dữ liệu.', 1;
GO
PRINT N'== B2. Ca 1a — số yêu cầu Pending (Q02) và 5 dòng đầu ==';
SELECT COUNT_BIG(*) AS PendingRequests, SUM(CAST(RequestedQty AS BIGINT)) AS PendingQty
FROM dbo.ReliefRequest WHERE Status = 'Pending';
DECLARE @q NVARCHAR(MAX) = (SELECT Stmt FROM lab.Query WHERE QueryID = 'Q02');
CREATE TABLE #q02 (RequestID INT, RegionID INT, RegionName NVARCHAR(100), ItemID INT, ItemName NVARCHAR(100),
                   Unit NVARCHAR(20), RequestedQty INT, CreatedAt DATETIME2);
INSERT #q02 EXEC sys.sp_executesql @q;
SELECT TOP (5) * FROM #q02 ORDER BY CreatedAt, RequestID;
GO
PRINT N'== B3. Ca 1b — tổng còn phải cấp (Q03): toàn hệ thống và theo vùng ==';
DECLARE @q NVARCHAR(MAX) = (SELECT Stmt FROM lab.Query WHERE QueryID = 'Q03');
CREATE TABLE #q03 (RegionID INT, ItemID INT, ActiveRequests BIGINT, OutstandingQty BIGINT);
INSERT #q03 EXEC sys.sp_executesql @q;
SELECT COUNT(*) AS RegionItemPairs, SUM(ActiveRequests) AS ActiveRequests, SUM(OutstandingQty) AS OutstandingQty FROM #q03;
SELECT RegionID, SUM(ActiveRequests) AS ActiveRequests, SUM(OutstandingQty) AS OutstandingQty
FROM #q03 GROUP BY RegionID ORDER BY RegionID;
-- Đối chiếu độc lập: tổng còn thiếu tính trực tiếp từng yêu cầu (OUTER APPLY tương quan)
DECLARE @cross BIGINT =
   (SELECT SUM(CAST(r.RequestedQty AS BIGINT) - ISNULL(x.Disp, 0))
    FROM dbo.ReliefRequest r
    OUTER APPLY (SELECT SUM(CAST(d.DispatchedQty AS BIGINT)) AS Disp FROM dbo.DispatchOrder d
                 WHERE d.RequestID = r.RequestID) x
    WHERE r.Status IN ('Pending','Approved','PartiallyDispatched'));
SELECT @cross AS OutstandingQty_CrossCheck;
IF (SELECT SUM(OutstandingQty) FROM #q03) <> @cross
    THROW 50031, N'Q03 lệch với phép đối chiếu độc lập.', 1;
GO
PRINT N'== B4. Ca 2 (Q04) — tổng quan, vùng không có kho, 10 dòng thiếu nhiều nhất ==';
DECLARE @q NVARCHAR(MAX) = (SELECT Stmt FROM lab.Query WHERE QueryID = 'Q04');
CREATE TABLE #q04 (RegionID INT, RegionName NVARCHAR(100), ItemID INT, ItemName NVARCHAR(100), Unit NVARCHAR(20),
                   OutstandingQty BIGINT, LocalAvailable BIGINT, CanFulfil BIGINT, ShortfallAfterLocal BIGINT);
INSERT #q04 EXEC sys.sp_executesql @q;
SELECT COUNT(*) AS RegionItemPairs, SUM(OutstandingQty) AS OutstandingQty, SUM(CanFulfil) AS CanFulfilLocally,
       SUM(ShortfallAfterLocal) AS ShortfallAfterLocal,
       SUM(CASE WHEN ShortfallAfterLocal > 0 THEN 1 ELSE 0 END) AS PairsStillShort
FROM #q04;
SELECT RegionID, RegionName, COUNT(*) AS Items, SUM(OutstandingQty) AS OutstandingQty,
       SUM(LocalAvailable) AS LocalAvailable, SUM(ShortfallAfterLocal) AS ShortfallAfterLocal
FROM #q04 WHERE RegionID = 19 GROUP BY RegionID, RegionName;   -- vùng 19 không có kho -> LocalAvailable = 0
SELECT TOP (10) * FROM #q04 ORDER BY ShortfallAfterLocal DESC, RegionID, ItemID;
PRINT N'== B5. Tình huống kiểm chứng Ca 2: vùng 20, Nước uống (kỳ vọng 60 / 45 / 15) ==';
SELECT * FROM #q04 WHERE RegionID = 20 AND ItemID = 1;
IF NOT EXISTS (SELECT 1 FROM #q04 WHERE RegionID = 20 AND ItemID = 1
               AND OutstandingQty = 60 AND LocalAvailable = 45 AND CanFulfil = 45 AND ShortfallAfterLocal = 15)
    THROW 50032, N'Tình huống kiểm chứng Ca 2 KHÔNG ra 60/45/15.', 1;
PRINT N'   -> ĐẠT: còn phải cấp 60, đáp ứng tại chỗ 45, còn thiếu 15.';
-- Ràng buộc nội tại của kết quả
IF EXISTS (SELECT 1 FROM #q04 WHERE CanFulfil > OutstandingQty OR CanFulfil > LocalAvailable
                                 OR ShortfallAfterLocal < 0 OR OutstandingQty <= 0)
    THROW 50033, N'Kết quả Ca 2 vi phạm ràng buộc min(nhu cầu, tồn).', 1;
GO
/* =====================================================================
   ĐO BASELINE (chỉ clustered PK). Mã ca: BASE-Qxx
   ===================================================================== */
EXEC lab.usp_MeasureQ 'BASE-Q01', 'R1 hot',  'Q01', N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'BASE-Q01', 'R16 low', 'Q01', N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'BASE-Q02', 'all',     'Q02';
EXEC lab.usp_MeasureQ 'BASE-Q03', 'all',     'Q03';
EXEC lab.usp_MeasureQ 'BASE-Q04', 'all',     'Q04';
EXEC lab.usp_MeasureQ 'BASE-Q05', 'R20 item1', 'Q05', N'@RegionID = 20, @ItemID = 1';
EXEC lab.usp_MeasureQ 'BASE-Q06', 'W1 I14 Q2', 'Q06', N'@WarehouseID = 1, @ItemID = 14, @From = ''2025-04-01'', @To = ''2025-07-01''';
EXEC lab.usp_MeasureQ 'BASE-Q07', 'Q2-2025',   'Q07', N'@From = ''2025-04-01'', @To = ''2025-07-01''';
EXEC lab.usp_MeasureQ 'BASE-Q08', 'W5 page3',  'Q08', N'@WarehouseID = 5, @Skip = 100';
GO
PRINT N'== Tổng hợp baseline (pass hiện tại) ==';
SELECT m.CaseID, m.Variant, m.RowsReturned, m.MedianReads, m.MedianCpuMs, m.MedianElapsedMs
FROM lab.vMeasureSummary m
WHERE m.PassNo = (SELECT PassNo FROM lab.RunContext) AND m.CaseID LIKE 'BASE-%'
ORDER BY m.CaseID, m.Variant;
GO
