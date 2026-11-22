/* =====================================================================
   04_lab_indexing.sql — Lab 1: scan/seek, Key Lookup vs covering, thứ tự cột
   khóa, missing-index DMV, hai index của báo cáo, index cho Ca 1.
   Đầu vào: lab.usp_ResetLab (chỉ clustered PK, stats FULLSCAN, compat 170).
   Mỗi biến thể: xóa plan cache của DB (biên dịch theo đúng tham số của nó),
   làm nóng 1 lần, đo 5 lần, lấy trung vị. Plan thật lấy ở lượt PLAN riêng.
   Mỗi bước chỉ thay ĐÚNG MỘT index; truy vấn, cột trả về, tham số giữ nguyên.
   Ca xuyên suốt (Q01): Pending của một vùng, [2025-03-01, 2025-09-01),
   vùng nhiều = R1, vùng ít = R16. Bước filtered index nằm ở 07 (cùng CaseID).
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
EXEC lab.usp_ResetLab;
GO
/* ---------------------------------------------------------------------
   L1.1  Ca 3 — S0 baseline (chỉ PK): kỳ vọng Clustered Index Scan + Sort
   --------------------------------------------------------------------- */
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16 NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S0 baseline PK only | R1',  'Q01', @R1;
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S0 baseline PK only | R16', 'Q01', @R16;
GO
/* L1.2  Missing-index DMV ngay sau khi chạy baseline (gợi ý của optimizer) */
PRINT N'== L1.2 Missing-index DMV cho ReliefRequest (sau baseline) ==';
SELECT d.statement AS TableName, d.equality_columns, d.inequality_columns, d.included_columns,
       s.user_seeks, s.user_scans, CAST(s.avg_total_user_cost AS DECIMAL(10,4)) AS avg_total_user_cost,
       s.avg_user_impact
FROM sys.dm_db_missing_index_details d
JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID() AND d.object_id = OBJECT_ID(N'dbo.ReliefRequest');
GO
/* ---------------------------------------------------------------------
   L1.3  Ca 3 — S1 chỉ mục của báo cáo (Mã nguồn 1.1)
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
GO
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16 NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S1 IXReliefRequestRegionStatus | R1',  'Q01', @R1;
EXEC lab.usp_MeasureQ 'CA3-IDX', 'S1 IXReliefRequestRegionStatus | R16', 'Q01', @R16;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R1',  'S1 IXReliefRequestRegionStatus | R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R16', 'S1 IXReliefRequestRegionStatus | R16', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   L1.4  Key Lookup vs covering: cùng khóa (RegionID, Status, CreatedAt)
         nhưng KHÔNG INCLUDE -> ItemID, RequestedQty phải lấy qua Key Lookup.
         (thay index báo cáo bằng bản hẹp; chỉ khác phần INCLUDE)
   --------------------------------------------------------------------- */
DROP INDEX IXReliefRequestRegionStatus ON dbo.ReliefRequest;
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatusNarrow
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt);
GO
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16 NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'L1.4 narrow no INCLUDE | R1',  'Q01', @R1;
EXEC lab.usp_MeasureQ 'CA3-IDX', 'L1.4 narrow no INCLUDE | R16', 'Q01', @R16;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R1',  'L1.4 narrow no INCLUDE | R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R16', 'L1.4 narrow no INCLUDE | R16', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   L1.5  Thứ tự cột khóa: đưa cột phạm vi CreatedAt lên đầu
         (CreatedAt, RegionID, Status) INCLUDE (ItemID, RequestedQty) — cùng cột,
         cùng INCLUDE với index báo cáo, chỉ khác thứ tự khóa.
   --------------------------------------------------------------------- */
DROP INDEX IXReliefRequestRegionStatusNarrow ON dbo.ReliefRequest;
CREATE NONCLUSTERED INDEX IXReliefRequestCreatedRegionStatus
    ON dbo.ReliefRequest (CreatedAt, RegionID, Status) INCLUDE (ItemID, RequestedQty);
GO
DECLARE @R1  NVARCHAR(200) = N'@RegionID = 1,  @From = ''2025-03-01'', @To = ''2025-09-01''';
DECLARE @R16 NVARCHAR(200) = N'@RegionID = 16, @From = ''2025-03-01'', @To = ''2025-09-01''';
EXEC lab.usp_MeasureQ 'CA3-IDX', 'L1.5 key order CreatedAt first | R1',  'Q01', @R1;
EXEC lab.usp_MeasureQ 'CA3-IDX', 'L1.5 key order CreatedAt first | R16', 'Q01', @R16;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R1',  'L1.5 key order CreatedAt first | R1',  @OrderMatters = 1;
EXEC lab.usp_CheckSame 'CA3-IDX', 'S0 baseline PK only | R16', 'L1.5 key order CreatedAt first | R16', @OrderMatters = 1;
GO
DROP INDEX IXReliefRequestCreatedRegionStatus ON dbo.ReliefRequest;
GO
/* ---------------------------------------------------------------------
   L1.6  Chỉ mục thứ hai của báo cáo: IXDispatchOrderWarehouseItem
         Q06 — lịch sử xuất của kho 1, vật phẩm 14, quý 2/2025
   --------------------------------------------------------------------- */
DECLARE @P NVARCHAR(300) = N'@WarehouseID = 1, @ItemID = 14, @From = ''2025-04-01'', @To = ''2025-07-01''';
EXEC lab.usp_MeasureQ 'Q06-IDX', 'before (PK only)', 'Q06', @P;
CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseItem
    ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID);
EXEC lab.usp_MeasureQ 'Q06-IDX', 'after IXDispatchOrderWarehouseItem', 'Q06', @P;
EXEC lab.usp_CheckSame 'Q06-IDX', 'before (PK only)', 'after IXDispatchOrderWarehouseItem', @OrderMatters = 1;
DROP INDEX IXDispatchOrderWarehouseItem ON dbo.DispatchOrder;
GO
/* ---------------------------------------------------------------------
   L1.7  Ca 1 — index DispatchOrder(RequestID) INCLUDE (DispatchedQty)
         cho phép cộng lượng đã xuất theo RequestID (Q03) và Ca 2 (Q04).
   --------------------------------------------------------------------- */
EXEC lab.usp_MeasureQ 'CA1-IDX', 'Q03 before (PK only)', 'Q03';
EXEC lab.usp_MeasureQ 'CA1-IDX', 'Q04 before (PK only)', 'Q04';
CREATE NONCLUSTERED INDEX IXDispatchOrderRequest
    ON dbo.DispatchOrder (RequestID) INCLUDE (DispatchedQty);
EXEC lab.usp_MeasureQ 'CA1-IDX', 'Q03 after IXDispatchOrderRequest', 'Q03';
EXEC lab.usp_MeasureQ 'CA1-IDX', 'Q04 after IXDispatchOrderRequest', 'Q04';
EXEC lab.usp_CheckSame 'CA1-IDX', 'Q03 before (PK only)', 'Q03 after IXDispatchOrderRequest', @OrderMatters = 1;
EXEC lab.usp_CheckSame 'CA1-IDX', 'Q04 before (PK only)', 'Q04 after IXDispatchOrderRequest', @OrderMatters = 1;
GO
/* ---------------------------------------------------------------------
   Kích thước các index đã thử (trang 8 KB) — tạo lại tạm để đo rồi xóa
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatusNarrow
    ON dbo.ReliefRequest (RegionID, Status, CreatedAt);
CREATE NONCLUSTERED INDEX IXReliefRequestCreatedRegionStatus
    ON dbo.ReliefRequest (CreatedAt, RegionID, Status) INCLUDE (ItemID, RequestedQty);
CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseItem
    ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID);
PRINT N'== Kích thước index (used pages) ==';
SELECT OBJECT_NAME(ps.object_id) AS TableName, i.name AS IndexName, i.type_desc,
       ps.row_count, ps.used_page_count, ps.in_row_data_page_count
FROM sys.dm_db_partition_stats ps JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE ps.object_id IN (OBJECT_ID(N'dbo.ReliefRequest'), OBJECT_ID(N'dbo.DispatchOrder'))
ORDER BY TableName, i.index_id;
DROP INDEX IXReliefRequestRegionStatusNarrow ON dbo.ReliefRequest;
DROP INDEX IXReliefRequestCreatedRegionStatus ON dbo.ReliefRequest;
GO
PRINT N'== Tổng hợp Lab 04 (pass hiện tại) ==';
SELECT m.CaseID, m.Variant, m.RowsReturned, m.MedianReads, m.MinReads, m.MaxReads, m.MedianCpuMs, m.MedianElapsedMs
FROM lab.vMeasureSummary m
WHERE m.PassNo = (SELECT PassNo FROM lab.RunContext) AND m.CaseID IN ('CA3-IDX','Q06-IDX','CA1-IDX')
ORDER BY m.CaseID, m.Variant;
SELECT CaseID, VariantA, VariantB, RowsA, RowsB, BagEqual, OrderEqual, Expected
FROM lab.Equivalence WHERE PassNo = (SELECT PassNo FROM lab.RunContext) AND CaseID IN ('CA3-IDX','Q06-IDX','CA1-IDX')
ORDER BY EquivalenceID;
GO
