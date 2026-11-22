/* =====================================================================
   05_lab_sargable.sql — Lab 2: điều kiện SARGable
   Đầu vào: lab.usp_ResetLab + các index nêu ở từng phần (covering để chỉ
   cách viết điều kiện là khác nhau). Mỗi cặp phải trả cùng kết quả (kiểm
   bằng dấu vân tay, có số lần xuất hiện và thứ tự); riêng LIKE '%...' không
   có phép viết lại tương đương nên chỉ ghi nhận quan sát.
   Collation database: SQL_Latin1_General_CP1_CI_AS (xem 01_create_schema.log).
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
/* ---------------------------------------------------------------------
   S1. Hàm trên cột ngày — AuditLog của một ngày (15/06/2025)
   Index: IXAuditLogLoggedAt (LoggedAt) INCLUDE (WarehouseID, ItemID, ActionType, DeltaQty)
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXAuditLogLoggedAt
    ON dbo.AuditLog (LoggedAt) INCLUDE (WarehouseID, ItemID, ActionType, DeltaQty);
GO
DECLARE @pd NVARCHAR(100) = N'@Day DATE', @pv NVARCHAR(100) = N'@Day = ''2025-06-15''';
EXEC lab.usp_Measure 'S1-DATE', 'a YEAR()/MONTH()/DAY() on column', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT LogID, WarehouseID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE YEAR(LoggedAt) = YEAR(@Day) AND MONTH(LoggedAt) = MONTH(@Day) AND DAY(LoggedAt) = DAY(@Day)
ORDER BY LoggedAt, LogID;';
EXEC lab.usp_Measure 'S1-DATE', 'b CONVERT(CHAR(8), column, 112)', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT LogID, WarehouseID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE CONVERT(CHAR(8), LoggedAt, 112) = CONVERT(CHAR(8), @Day, 112)
ORDER BY LoggedAt, LogID;';
EXEC lab.usp_Measure 'S1-DATE', 'c CAST(column AS DATE)', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT LogID, WarehouseID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE CAST(LoggedAt AS DATE) = @Day
ORDER BY LoggedAt, LogID;';
EXEC lab.usp_Measure 'S1-DATE', 'd half-open range on column', @ParamDef = @pd, @ParamVals = @pv, @Stmt = N'
SELECT LogID, WarehouseID, ItemID, ActionType, DeltaQty, LoggedAt
FROM dbo.AuditLog
WHERE LoggedAt >= @Day AND LoggedAt < DATEADD(DAY, 1, CAST(@Day AS DATETIME2))
ORDER BY LoggedAt, LogID;';
EXEC lab.usp_CheckSame 'S1-DATE', 'a YEAR()/MONTH()/DAY() on column', 'd half-open range on column', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'S1-DATE', 'b CONVERT(CHAR(8), column, 112)',  'd half-open range on column', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'S1-DATE', 'c CAST(column AS DATE)',           'd half-open range on column', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   S2. Kiểu tham số VARCHAR vs NVARCHAR trên cột VARCHAR
   S2a: Donor.Phone VARCHAR(20) — Index IXDonorPhone (Phone) INCLUDE (DonorName)
   S2b: ReliefRequest.Status VARCHAR(20) trong ca Q01 — index của báo cáo
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXDonorPhone ON dbo.Donor (Phone) INCLUDE (DonorName);
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
GO
DECLARE @phone VARCHAR(20) = (SELECT Phone FROM dbo.Donor WHERE DonorID = 1234);
DECLARE @pv NVARCHAR(100) = N'@Phone = ''' + @phone + N'''';
SELECT @phone AS PhoneOfDonor1234;
EXEC lab.usp_Measure 'S2-PHONE', 'a @Phone VARCHAR(20)', @ParamDef = N'@Phone VARCHAR(20)', @ParamVals = @pv, @Stmt = N'
SELECT DonorID, DonorName, Phone FROM dbo.Donor WHERE Phone = @Phone ORDER BY DonorID;';
EXEC lab.usp_Measure 'S2-PHONE', 'b @Phone NVARCHAR(20)', @ParamDef = N'@Phone NVARCHAR(20)', @ParamVals = @pv, @Stmt = N'
SELECT DonorID, DonorName, Phone FROM dbo.Donor WHERE Phone = @Phone ORDER BY DonorID;';
EXEC lab.usp_CheckSame 'S2-PHONE', 'a @Phone VARCHAR(20)', 'b @Phone NVARCHAR(20)', @OrderMatters = 1;
GO
DECLARE @pv NVARCHAR(200) = N'@RegionID = 1, @Status = ''Pending'', @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_Measure 'S2-STATUS', 'a @Status VARCHAR(20) | R1', @ParamVals = @pv,
     @ParamDef = N'@RegionID INT, @Status VARCHAR(20), @From DATETIME2, @To DATETIME2', @Stmt = N'
SELECT RequestID, ItemID, RequestedQty, CreatedAt
FROM dbo.ReliefRequest
WHERE RegionID = @RegionID AND Status = @Status
  AND CreatedAt >= @From AND CreatedAt < @To
ORDER BY CreatedAt, RequestID;';
EXEC lab.usp_Measure 'S2-STATUS', 'b @Status NVARCHAR(20) | R1', @ParamVals = @pv,
     @ParamDef = N'@RegionID INT, @Status NVARCHAR(20), @From DATETIME2, @To DATETIME2', @Stmt = N'
SELECT RequestID, ItemID, RequestedQty, CreatedAt
FROM dbo.ReliefRequest
WHERE RegionID = @RegionID AND Status = @Status
  AND CreatedAt >= @From AND CreatedAt < @To
ORDER BY CreatedAt, RequestID;';
EXEC lab.usp_CheckSame 'S2-STATUS', 'a @Status VARCHAR(20) | R1', 'b @Status NVARCHAR(20) | R1', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   S3. LIKE có ký tự đại diện đầu chuỗi — Donor.DonorName
   Index: IXDonorName (DonorName). Hai câu hỏi KHÁC nghĩa (hậu tố vs tiền tố):
   không có phép viết lại tương đương cho '%x' trên lược đồ hiện tại -> chỉ ghi nhận.
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXDonorName ON dbo.Donor (DonorName);
GO
EXEC lab.usp_Measure 'S3-LIKE', 'a LIKE ''%'' + suffix (ma 01234)', @ParamDef = N'@Suffix NVARCHAR(20)', @ParamVals = N'@Suffix = N''01234''', @Stmt = N'
SELECT DonorID, DonorName FROM dbo.Donor WHERE DonorName LIKE N''%'' + @Suffix ORDER BY DonorName, DonorID;';
EXEC lab.usp_Measure 'S3-LIKE', 'b LIKE prefix + ''%'' (Nguyen Van An...)', @ParamDef = N'@Prefix NVARCHAR(60)', @ParamVals = N'@Prefix = N''Nguyễn Văn An''', @Stmt = N'
SELECT DonorID, DonorName FROM dbo.Donor WHERE DonorName LIKE @Prefix + N''%'' ORDER BY DonorName, DonorID;';
GO
/* ---------------------------------------------------------------------
   S4. OR trên hai cột khác nhau vs UNION ALL
   "Các lượt xuất thuộc yêu cầu @RequestID hoặc do nhà tài trợ @DonorID tài trợ"
   Index (đều covering): IXDispatchOrderRequestCover (RequestID) INCLUDE (DonorID, DispatchedQty)
                         IXDispatchOrderDonorCover   (DonorID)   INCLUDE (RequestID, DispatchedQty)
   UNION ALL loại dòng trùng bằng điều kiện bù RequestID <> @RequestID (RequestID NOT NULL).
   Chọn @DonorID là nhà tài trợ của chính một lượt xuất thuộc @RequestID để có dòng thỏa CẢ HAI vế.
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXDispatchOrderRequestCover ON dbo.DispatchOrder (RequestID) INCLUDE (DonorID, DispatchedQty);
CREATE NONCLUSTERED INDEX IXDispatchOrderDonorCover   ON dbo.DispatchOrder (DonorID)   INCLUDE (RequestID, DispatchedQty);
GO
-- Yêu cầu đầu tiên từ 12345 trở đi có >= 2 lượt xuất đều có nhà tài trợ
DECLARE @req INT = (SELECT MIN(RequestID) FROM (
                        SELECT RequestID FROM dbo.DispatchOrder WHERE RequestID >= 12345
                        GROUP BY RequestID HAVING COUNT(*) >= 2 AND COUNT(DonorID) = COUNT(*)) x);
DECLARE @don INT = (SELECT MIN(DonorID) FROM dbo.DispatchOrder WHERE RequestID = @req AND DonorID IS NOT NULL);
IF @req IS NULL OR @don IS NULL THROW 50040, N'Không chọn được tham số cho S4.', 1;
DECLARE @pv NVARCHAR(100) = CONCAT(N'@RequestID = ', @req, N', @DonorID = ', @don);
SELECT @req AS RequestID, @don AS DonorID,
       (SELECT COUNT(*) FROM dbo.DispatchOrder WHERE RequestID = @req) AS RowsByRequest,
       (SELECT COUNT(*) FROM dbo.DispatchOrder WHERE DonorID = @don) AS RowsByDonor,
       (SELECT COUNT(*) FROM dbo.DispatchOrder WHERE RequestID = @req AND DonorID = @don) AS RowsMatchingBoth;
EXEC lab.usp_Measure 'S4-OR', 'a OR', @ParamDef = N'@RequestID INT, @DonorID INT', @ParamVals = @pv, @Stmt = N'
SELECT DispatchID, RequestID, DonorID, DispatchedQty
FROM dbo.DispatchOrder
WHERE RequestID = @RequestID OR DonorID = @DonorID
ORDER BY DispatchID;';
EXEC lab.usp_Measure 'S4-OR', 'b UNION ALL (bu trung)', @ParamDef = N'@RequestID INT, @DonorID INT', @ParamVals = @pv, @Stmt = N'
SELECT DispatchID, RequestID, DonorID, DispatchedQty
FROM dbo.DispatchOrder WHERE RequestID = @RequestID
UNION ALL
SELECT DispatchID, RequestID, DonorID, DispatchedQty
FROM dbo.DispatchOrder WHERE DonorID = @DonorID AND RequestID <> @RequestID
ORDER BY DispatchID;';
EXEC lab.usp_CheckSame 'S4-OR', 'a OR', 'b UNION ALL (bu trung)', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   S5. ISNULL trong WHERE — tổng lượng xuất theo nhà tài trợ, NULL = không qua nhà tài trợ
   Index: IXDispatchOrderDonorCover (DonorID) INCLUDE (RequestID, DispatchedQty)
   ISNULL(DonorID, 0) tương đương vì DonorID là FK tới Donor(1..5000), không có giá trị 0.
   --------------------------------------------------------------------- */
DECLARE @s5a NVARCHAR(MAX) = N'
SELECT COUNT_BIG(*) AS Dispatches, SUM(CAST(DispatchedQty AS BIGINT)) AS TotalQty
FROM dbo.DispatchOrder
WHERE ISNULL(DonorID, 0) = ISNULL(@DonorID, 0);';
DECLARE @s5b NVARCHAR(MAX) = N'
SELECT COUNT_BIG(*) AS Dispatches, SUM(CAST(DispatchedQty AS BIGINT)) AS TotalQty
FROM dbo.DispatchOrder
WHERE DonorID = @DonorID OR (DonorID IS NULL AND @DonorID IS NULL);';
EXEC lab.usp_Measure 'S5-ISNULL', 'a ISNULL(col) | DonorID=777',  @Stmt = @s5a, @ParamDef = N'@DonorID INT', @ParamVals = N'@DonorID = 777';
EXEC lab.usp_Measure 'S5-ISNULL', 'b OR IS NULL | DonorID=777',   @Stmt = @s5b, @ParamDef = N'@DonorID INT', @ParamVals = N'@DonorID = 777';
EXEC lab.usp_Measure 'S5-ISNULL', 'a ISNULL(col) | DonorID=NULL', @Stmt = @s5a, @ParamDef = N'@DonorID INT', @ParamVals = N'@DonorID = NULL';
EXEC lab.usp_Measure 'S5-ISNULL', 'b OR IS NULL | DonorID=NULL',  @Stmt = @s5b, @ParamDef = N'@DonorID INT', @ParamVals = N'@DonorID = NULL';
EXEC lab.usp_CheckSame 'S5-ISNULL', 'a ISNULL(col) | DonorID=777',  'b OR IS NULL | DonorID=777',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'S5-ISNULL', 'a ISNULL(col) | DonorID=NULL', 'b OR IS NULL | DonorID=NULL', @OrderMatters = 1;
GO
PRINT N'== Tổng hợp Lab 05 (pass hiện tại) ==';
SELECT m.CaseID, m.Variant, m.RowsReturned, m.MedianReads, m.MinReads, m.MaxReads, m.MedianCpuMs, m.MedianElapsedMs
FROM lab.vMeasureSummary m
WHERE m.PassNo = (SELECT PassNo FROM lab.RunContext) AND m.CaseID LIKE 'S[1-5]-%'
ORDER BY m.CaseID, m.Variant;
SELECT CaseID, VariantA, VariantB, RowsA, RowsB, BagEqual, OrderEqual, Expected
FROM lab.Equivalence WHERE PassNo = (SELECT PassNo FROM lab.RunContext) AND CaseID LIKE 'S[1-5]-%'
ORDER BY EquivalenceID;
GO
