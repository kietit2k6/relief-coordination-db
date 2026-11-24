/* =====================================================================
   02_indexes.sql — TRẠNG THÁI TRIỂN KHAI (DEPLOYED) của index phụ.
   Đúng hai Non-Clustered Index của Mã nguồn 1.1 (quyết định N6):
     IXReliefRequestRegionStatus   ON ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty)
     IXDispatchOrderWarehouseItem  ON DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID)
   Trạng thái này KHÁC baseline đo S0 của lab (chỉ PK). Lab tự chuyển DEPLOYED -> S0
   (lab/L00_enter_lab.sql) và trả về DEPLOYED bằng chính file này (lab/L99_cleanup.sql).

   Chạy lại an toàn: chỉ tạo index còn thiếu; index cùng tên nhưng khác định nghĩa -> THROW.
   Index phụ KHÁC hai index này (index của lab) không bị xóa ở đây, chỉ được báo ra.
   ===================================================================== */
SET NOCOUNT ON;
USE DisasterReliefDB;
GO
IF OBJECT_ID(N'dbo.ReliefRequest') IS NULL OR OBJECT_ID(N'dbo.DispatchOrder') IS NULL
    THROW 50200, N'Chưa có bảng — chạy 01_schema.sql trước.', 1;

DECLARE @want TABLE (TableName sysname, IndexName sysname, Def NVARCHAR(400));
INSERT @want VALUES
 (N'ReliefRequest', N'IXReliefRequestRegionStatus',  N'RegionID,Status,CreatedAt|ItemID,RequestedQty|'),
 (N'DispatchOrder', N'IXDispatchOrderWarehouseItem', N'WarehouseID,ItemID,DispatchedAt|DispatchedQty,RequestID|');

DECLARE @have TABLE (TableName sysname, IndexName sysname, Def NVARCHAR(400));
INSERT @have
SELECT OBJECT_NAME(i.object_id), i.name,
       CONCAT((SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal)
               FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0), N'|',
              (SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.index_column_id)
               FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1), N'|',
              i.filter_definition)
FROM sys.indexes i
WHERE i.object_id IN (OBJECT_ID(N'dbo.ReliefRequest'), OBJECT_ID(N'dbo.DispatchOrder')) AND i.index_id > 1;

IF EXISTS (SELECT 1 FROM @want w JOIN @have h ON h.IndexName = w.IndexName WHERE h.Def <> w.Def OR h.TableName <> w.TableName)
    THROW 50201, N'Index cùng tên đã tồn tại nhưng khác định nghĩa của Mã nguồn 1.1 — dừng.', 1;
GO
IF INDEXPROPERTY(
    OBJECT_ID(N'dbo.ReliefRequest'),
    N'IXReliefRequestRegionStatus',
    'IndexID'
) IS NULL
BEGIN
    CREATE NONCLUSTERED INDEX IXReliefRequestRegionStatus
        ON dbo.ReliefRequest (RegionID, Status, CreatedAt) INCLUDE (ItemID, RequestedQty);
    PRINT N'Đã tạo IXReliefRequestRegionStatus.';
END
ELSE PRINT N'IXReliefRequestRegionStatus đã có.';

IF INDEXPROPERTY(OBJECT_ID(N'dbo.DispatchOrder'), N'IXDispatchOrderWarehouseItem', 'IndexID') IS NULL
BEGIN
    CREATE NONCLUSTERED INDEX IXDispatchOrderWarehouseItem
        ON dbo.DispatchOrder (WarehouseID, ItemID, DispatchedAt) INCLUDE (DispatchedQty, RequestID);
    PRINT N'Đã tạo IXDispatchOrderWarehouseItem.';
END
ELSE PRINT N'IXDispatchOrderWarehouseItem đã có.';
GO
/* Báo các index phụ ngoài trạng thái triển khai (không xóa) */
SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.type_desc,
       CASE WHEN i.name IN (N'IXReliefRequestRegionStatus', N'IXDispatchOrderWarehouseItem')
            THEN N'DEPLOYED' ELSE N'NGOÀI TRẠNG THÁI TRIỂN KHAI (index lab?)' END AS Role
FROM sys.indexes i
WHERE OBJECTPROPERTY(i.object_id, 'IsMsShipped') = 0 AND i.index_id > 1
ORDER BY TableName, IndexName;
GO
