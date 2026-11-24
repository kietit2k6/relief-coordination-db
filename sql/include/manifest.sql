/* =====================================================================
   include/manifest.sql — "dấu vân tay" dữ liệu của 9 bảng, dùng bởi 04
   và 98 (so với baseline đã công nhận). Kết quả: bảng tạm #manifest.
   DataSha256 = SHA-256 của chuỗi nối các SHA-256 từng dòng, sắp theo khóa chính.
   Mọi cột đều tham gia; NULL được mã hóa '~' để không lẫn với chuỗi rỗng; ngày giờ theo kiểu 126.
   ===================================================================== */
IF OBJECT_ID(N'tempdb..#manifest') IS NOT NULL DROP TABLE #manifest;
CREATE TABLE #manifest (TableName sysname PRIMARY KEY, RowsCount BIGINT, DataSha256 CHAR(64));
GO
INSERT #manifest
SELECT N'Region', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', RegionID, RegionName, SeverityLevel, AffectedPop)), 2)), '') WITHIN GROUP (ORDER BY RegionID)), 2)
FROM dbo.Region
;
INSERT #manifest
SELECT N'Warehouse', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', WarehouseID, RegionID, WarehouseName, Capacity)), 2)), '') WITHIN GROUP (ORDER BY WarehouseID)), 2)
FROM dbo.Warehouse
;
INSERT #manifest
SELECT N'Category', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', CategoryID, CategoryName, CAST(IsPerishable AS INT))), 2)), '') WITHIN GROUP (ORDER BY CategoryID)), 2)
FROM dbo.Category
;
INSERT #manifest
SELECT N'Item', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', ItemID, CategoryID, ItemName, Unit, UnitWeight)), 2)), '') WITHIN GROUP (ORDER BY ItemID)), 2)
FROM dbo.Item
;
INSERT #manifest
SELECT N'Donor', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', DonorID, DonorName, DonorType, ISNULL(Phone, '~'))), 2)), '') WITHIN GROUP (ORDER BY DonorID)), 2)
FROM dbo.Donor
;
INSERT #manifest
SELECT N'Inventory', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', WarehouseID, ItemID, Quantity, ReservedQty, CONVERT(VARCHAR(27), UpdatedAt, 126))), 2)), '')
           WITHIN GROUP (ORDER BY WarehouseID, ItemID)), 2)
FROM dbo.Inventory
;
INSERT #manifest
SELECT N'ReliefRequest', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', RequestID, RegionID, ItemID, RequestedQty, Status, CONVERT(VARCHAR(27), CreatedAt, 126))), 2)), '')
           WITHIN GROUP (ORDER BY RequestID)), 2)
FROM dbo.ReliefRequest
;
INSERT #manifest
SELECT N'DispatchOrder', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', DispatchID, RequestID, WarehouseID, ItemID, ISNULL(CAST(DonorID AS VARCHAR(11)), '~'),
                     DispatchedQty, CONVERT(VARCHAR(27), DispatchedAt, 126))), 2)), '')
           WITHIN GROUP (ORDER BY DispatchID)), 2)
FROM dbo.DispatchOrder
;
INSERT #manifest
SELECT N'AuditLog', COUNT_BIG(*), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
       STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(CHAR(64), HASHBYTES('SHA2_256',
           CONCAT_WS(N'|', LogID, WarehouseID, ItemID, ActionType, DeltaQty, CONVERT(VARCHAR(27), LoggedAt, 126))), 2)), '')
           WITHIN GROUP (ORDER BY LogID)), 2)
FROM dbo.AuditLog;
GO
