/* =====================================================================
   include/business_checks.sql — bộ kiểm tra cấu trúc + nghiệp vụ dùng chung cho
   04_verify_schema_data.sql
   Được nạp bằng ":r include/business_checks.sql" (sqlcmd / SSMS SQLCMD mode).
   Kết quả: bảng tạm #check (CheckID, Description, Expected, Actual, Pass). Không THROW ở đây.
   ===================================================================== */
IF OBJECT_ID(N'tempdb..#check') IS NOT NULL DROP TABLE #check;
CREATE TABLE #check (CheckID VARCHAR(20) PRIMARY KEY, Description NVARCHAR(200),
                     Expected NVARCHAR(100), Actual NVARCHAR(100), Pass BIT);
GO
/* ---------- S. Cấu trúc ---------- */
DECLARE @cols TABLE (t sysname, c sysname, typ sysname, len SMALLINT, prec TINYINT, scale TINYINT, nul BIT, ident BIT);
INSERT @cols VALUES
 (N'Region',N'RegionID',N'int',4,10,0,0,0),(N'Region',N'RegionName',N'nvarchar',200,0,0,0,0),
 (N'Region',N'SeverityLevel',N'tinyint',1,3,0,0,0),(N'Region',N'AffectedPop',N'int',4,10,0,0,0),
 (N'Warehouse',N'WarehouseID',N'int',4,10,0,0,0),(N'Warehouse',N'RegionID',N'int',4,10,0,0,0),
 (N'Warehouse',N'WarehouseName',N'nvarchar',200,0,0,0,0),(N'Warehouse',N'Capacity',N'int',4,10,0,0,0),
 (N'Category',N'CategoryID',N'int',4,10,0,0,0),(N'Category',N'CategoryName',N'nvarchar',160,0,0,0,0),
 (N'Category',N'IsPerishable',N'bit',1,1,0,0,0),
 (N'Item',N'ItemID',N'int',4,10,0,0,0),(N'Item',N'CategoryID',N'int',4,10,0,0,0),
 (N'Item',N'ItemName',N'nvarchar',200,0,0,0,0),(N'Item',N'Unit',N'nvarchar',40,0,0,0,0),
 (N'Item',N'UnitWeight',N'decimal',5,8,2,0,0),
 (N'Donor',N'DonorID',N'int',4,10,0,0,0),(N'Donor',N'DonorName',N'nvarchar',240,0,0,0,0),
 (N'Donor',N'DonorType',N'varchar',20,0,0,0,0),(N'Donor',N'Phone',N'varchar',20,0,0,1,0),
 (N'Inventory',N'WarehouseID',N'int',4,10,0,0,0),(N'Inventory',N'ItemID',N'int',4,10,0,0,0),
 (N'Inventory',N'Quantity',N'int',4,10,0,0,0),(N'Inventory',N'ReservedQty',N'int',4,10,0,0,0),
 (N'Inventory',N'UpdatedAt',N'datetime2',8,27,7,0,0),
 (N'ReliefRequest',N'RequestID',N'int',4,10,0,0,1),(N'ReliefRequest',N'RegionID',N'int',4,10,0,0,0),
 (N'ReliefRequest',N'ItemID',N'int',4,10,0,0,0),(N'ReliefRequest',N'RequestedQty',N'int',4,10,0,0,0),
 (N'ReliefRequest',N'Status',N'varchar',20,0,0,0,0),(N'ReliefRequest',N'CreatedAt',N'datetime2',8,27,7,0,0),
 (N'DispatchOrder',N'DispatchID',N'int',4,10,0,0,1),(N'DispatchOrder',N'RequestID',N'int',4,10,0,0,0),
 (N'DispatchOrder',N'WarehouseID',N'int',4,10,0,0,0),(N'DispatchOrder',N'ItemID',N'int',4,10,0,0,0),
 (N'DispatchOrder',N'DonorID',N'int',4,10,0,1,0),(N'DispatchOrder',N'DispatchedQty',N'int',4,10,0,0,0),
 (N'DispatchOrder',N'DispatchedAt',N'datetime2',8,27,7,0,0),
 (N'AuditLog',N'LogID',N'bigint',8,19,0,0,1),(N'AuditLog',N'WarehouseID',N'int',4,10,0,0,0),
 (N'AuditLog',N'ItemID',N'int',4,10,0,0,0),(N'AuditLog',N'ActionType',N'varchar',20,0,0,0,0),
 (N'AuditLog',N'DeltaQty',N'int',4,10,0,0,0),(N'AuditLog',N'LoggedAt',N'datetime2',8,27,7,0,0);

DECLARE @actualCols TABLE (t sysname, c sysname, typ sysname, len SMALLINT, prec TINYINT, scale TINYINT, nul BIT, ident BIT);
INSERT @actualCols
SELECT t.name, c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
WHERE SCHEMA_NAME(t.schema_id) = N'dbo';

DECLARE @tables INT = (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0);
DECLARE @nCols INT = (SELECT COUNT(*) FROM @actualCols);
DECLARE @colDiff INT = (SELECT COUNT(*) FROM (SELECT * FROM @cols EXCEPT SELECT * FROM @actualCols) a)
                     + (SELECT COUNT(*) FROM (SELECT * FROM @actualCols EXCEPT SELECT * FROM @cols) b);
INSERT #check VALUES
 ('S01', N'Số bảng người dùng (toàn DB)', N'9', @tables, IIF(@tables = 9, 1, 0)),
 ('S02', N'Số cột của 9 bảng dbo', N'44', @nCols, IIF(@nCols = 44, 1, 0)),
 ('S03', N'Cột lệch tên/kiểu/độ dài/NULL/IDENTITY so với Hình 1.4', N'0', @colDiff, IIF(@colDiff = 0, 1, 0));

DECLARE @pk NVARCHAR(400) = (SELECT STRING_AGG(CONCAT(OBJECT_NAME(k.parent_object_id), N'(', x.cols, N')'), N';')
                                    WITHIN GROUP (ORDER BY OBJECT_NAME(k.parent_object_id))
    FROM sys.key_constraints k
    CROSS APPLY (SELECT STRING_AGG(c.name, N',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS cols
                 FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = k.parent_object_id AND ic.index_id = k.unique_index_id) x
    WHERE k.type = 'PK');
DECLARE @pkWant NVARCHAR(400) = N'AuditLog(LogID);Category(CategoryID);DispatchOrder(DispatchID);Donor(DonorID);Inventory(WarehouseID,ItemID);Item(ItemID);Region(RegionID);ReliefRequest(RequestID);Warehouse(WarehouseID)';
INSERT #check VALUES ('S04', N'Khóa chính (Inventory là PK ghép WarehouseID, ItemID)', N'9 PK đúng cột', IIF(@pk = @pkWant, N'khớp', N'LỆCH'), IIF(@pk = @pkWant, 1, 0));

DECLARE @fk NVARCHAR(1000) = (SELECT STRING_AGG(CONCAT(OBJECT_NAME(f.parent_object_id), N'.', COL_NAME(fc.parent_object_id, fc.parent_column_id),
                                                       N'>', OBJECT_NAME(f.referenced_object_id)), N';')
                                     WITHIN GROUP (ORDER BY OBJECT_NAME(f.parent_object_id), COL_NAME(fc.parent_object_id, fc.parent_column_id))
    FROM sys.foreign_keys f JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = f.object_id);
DECLARE @fkWant NVARCHAR(1000) = N'DispatchOrder.DonorID>Donor;DispatchOrder.ItemID>Item;DispatchOrder.RequestID>ReliefRequest;DispatchOrder.WarehouseID>Warehouse;Inventory.ItemID>Item;Inventory.WarehouseID>Warehouse;Item.CategoryID>Category;ReliefRequest.ItemID>Item;ReliefRequest.RegionID>Region;Warehouse.RegionID>Region';
INSERT #check VALUES ('S05', N'10 khóa ngoại theo ERD (AuditLog không có FK — C2)', N'10 FK đúng', IIF(@fk = @fkWant, N'khớp', N'LỆCH'), IIF(@fk = @fkWant, 1, 0));

DECLARE @ck NVARCHAR(1000) = (SELECT STRING_AGG(CONCAT(OBJECT_NAME(parent_object_id), N':', definition), N';')
                                     WITHIN GROUP (ORDER BY OBJECT_NAME(parent_object_id), definition)
                              FROM sys.check_constraints);
DECLARE @ckWant NVARCHAR(1000) = N'Inventory:([Quantity]>=(0));Inventory:([ReservedQty]<=[Quantity]);Inventory:([ReservedQty]>=(0));Region:([SeverityLevel]>=(1) AND [SeverityLevel]<=(5))';
INSERT #check VALUES ('S06', N'4 CHECK theo DOCX/ERD (C3)', N'4 CHECK đúng', IIF(@ck = @ckWant, N'khớp', N'LỆCH'), IIF(@ck = @ckWant, 1, 0));

DECLARE @untrusted INT = (SELECT COUNT(*) FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1)
                       + (SELECT COUNT(*) FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1);
INSERT #check VALUES ('S07', N'FK/CHECK bị tắt hoặc untrusted', N'0', @untrusted, IIF(@untrusted = 0, 1, 0));

DECLARE @dflt INT = (SELECT COUNT(*) FROM sys.default_constraints dc
                     JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
                     WHERE CONCAT(OBJECT_NAME(dc.parent_object_id), N'.', c.name) IN
                       (N'Inventory.ReservedQty', N'Inventory.UpdatedAt', N'ReliefRequest.Status', N'ReliefRequest.CreatedAt',
                        N'DispatchOrder.DispatchedAt', N'AuditLog.LoggedAt'));
INSERT #check VALUES ('S08', N'DEFAULT cần cho các lệnh INSERT trong DOCX', N'6', @dflt, IIF(@dflt = 6, 1, 0));
GO
/* DBCC CHECKCONSTRAINTS: mọi dòng trả về là vi phạm */
IF OBJECT_ID(N'tempdb..#ccv') IS NOT NULL DROP TABLE #ccv;
CREATE TABLE #ccv (TableName NVARCHAR(400), ConstraintName NVARCHAR(400), WhereClause NVARCHAR(4000));
INSERT #ccv EXEC (N'DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, NO_INFOMSGS');
DECLARE @v INT = (SELECT COUNT(*) FROM #ccv);
INSERT #check VALUES ('S09', N'DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS — số vi phạm', N'0', @v, IIF(@v = 0, 1, 0));
GO
/* ---------- R. Số dòng (COUNT_BIG, không dùng metadata) ---------- */
DECLARE @c TABLE (n INT IDENTITY, t sysname, e BIGINT, a BIGINT);
INSERT @c (t, e, a) VALUES
 (N'Region',20,(SELECT COUNT_BIG(*) FROM dbo.Region)),
 (N'Warehouse',30,(SELECT COUNT_BIG(*) FROM dbo.Warehouse)),
 (N'Category',10,(SELECT COUNT_BIG(*) FROM dbo.Category)),
 (N'Item',200,(SELECT COUNT_BIG(*) FROM dbo.Item)),
 (N'Donor',5000,(SELECT COUNT_BIG(*) FROM dbo.Donor)),
 (N'Inventory',6000,(SELECT COUNT_BIG(*) FROM dbo.Inventory)),
 (N'ReliefRequest',50000,(SELECT COUNT_BIG(*) FROM dbo.ReliefRequest)),
 (N'DispatchOrder',100000,(SELECT COUNT_BIG(*) FROM dbo.DispatchOrder)),
 (N'AuditLog',100000,(SELECT COUNT_BIG(*) FROM dbo.AuditLog));
INSERT #check SELECT CONCAT('R', FORMAT(n, '00')), CONCAT(N'Số dòng ', t), e, a, IIF(a = e, 1, 0) FROM @c;
DECLARE @tot BIGINT = (SELECT SUM(a) FROM @c);
INSERT #check VALUES ('R10', N'Tổng số dòng (Bảng 1.2)', N'261260', @tot, IIF(@tot = 261260, 1, 0));
GO
/* ---------- B. Quy tắc nghiệp vụ ---------- */
DECLARE @x INT;
-- B01 tồn kho (CHECK đã bảo đảm, vẫn kiểm trên dữ liệu)
SELECT @x = COUNT(*) FROM dbo.Inventory WHERE Quantity < 0 OR ReservedQty < 0 OR ReservedQty > Quantity;
INSERT #check VALUES ('B01', N'Inventory: Quantity<0, ReservedQty<0 hoặc ReservedQty>Quantity', N'0', @x, IIF(@x = 0, 1, 0));
-- B02 Inventory đủ 30 x 200 cặp
SELECT @x = COUNT(*) FROM dbo.Warehouse w CROSS JOIN dbo.Item i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.Inventory v WHERE v.WarehouseID = w.WarehouseID AND v.ItemID = i.ItemID);
INSERT #check VALUES ('B02', N'Cặp (kho, vật phẩm) thiếu dòng tồn', N'0', @x, IIF(@x = 0, 1, 0));
-- B03 số lượng dương (không có CHECK theo C3, kiểm trên dữ liệu)
SELECT @x = (SELECT COUNT(*) FROM dbo.ReliefRequest WHERE RequestedQty <= 0)
          + (SELECT COUNT(*) FROM dbo.DispatchOrder WHERE DispatchedQty <= 0);
INSERT #check VALUES ('B03', N'RequestedQty<=0 hoặc DispatchedQty<=0', N'0', @x, IIF(@x = 0, 1, 0));
-- B04 tập trạng thái
SELECT @x = COUNT(*) FROM dbo.ReliefRequest
            WHERE Status NOT IN ('Pending','Approved','PartiallyDispatched','Delivered','Cancelled');
INSERT #check VALUES ('B04', N'Status ngoài 5 giá trị quy ước', N'0', @x, IIF(@x = 0, 1, 0));
-- B05 C6: vật phẩm xuất = vật phẩm yêu cầu
SELECT @x = COUNT(*) FROM dbo.DispatchOrder d JOIN dbo.ReliefRequest r ON r.RequestID = d.RequestID WHERE d.ItemID <> r.ItemID;
INSERT #check VALUES ('B05', N'DispatchOrder.ItemID khác ItemID của yêu cầu (C6)', N'0', @x, IIF(@x = 0, 1, 0));
-- B06 thời điểm
SELECT @x = COUNT(*) FROM dbo.DispatchOrder d JOIN dbo.ReliefRequest r ON r.RequestID = d.RequestID WHERE d.DispatchedAt < r.CreatedAt;
INSERT #check VALUES ('B06', N'Xuất trước thời điểm tạo yêu cầu', N'0', @x, IIF(@x = 0, 1, 0));
-- B07..B10 trạng thái và tổng đã xuất
DECLARE @wrong INT, @deliv INT, @part INT, @over INT;
;WITH s AS (SELECT RequestID, SUM(CAST(DispatchedQty AS BIGINT)) AS Disp FROM dbo.DispatchOrder GROUP BY RequestID)
SELECT @wrong = SUM(CASE WHEN r.Status IN ('Pending','Approved','Cancelled') AND s.Disp IS NOT NULL THEN 1 ELSE 0 END),
       @deliv = SUM(CASE WHEN r.Status = 'Delivered' AND ISNULL(s.Disp,0) <> r.RequestedQty THEN 1 ELSE 0 END),
       @part  = SUM(CASE WHEN r.Status = 'PartiallyDispatched' AND NOT (ISNULL(s.Disp,0) > 0 AND s.Disp < r.RequestedQty) THEN 1 ELSE 0 END),
       @over  = SUM(CASE WHEN s.Disp > r.RequestedQty THEN 1 ELSE 0 END)
FROM dbo.ReliefRequest r LEFT JOIN s ON s.RequestID = r.RequestID;
INSERT #check VALUES
 ('B07', N'Pending/Approved/Cancelled nhưng đã có dòng xuất', N'0', @wrong, IIF(@wrong = 0, 1, 0)),
 ('B08', N'Delivered nhưng tổng xuất <> yêu cầu', N'0', @deliv, IIF(@deliv = 0, 1, 0)),
 ('B09', N'PartiallyDispatched ngoài khoảng (0, yêu cầu)', N'0', @part, IIF(@part = 0, 1, 0)),
 ('B10', N'Tổng xuất vượt lượng yêu cầu', N'0', @over, IIF(@over = 0, 1, 0));
-- B11 kho xuất thuộc vùng của yêu cầu (vùng 19 không có kho -> kho 18)
SELECT @x = COUNT(*) FROM dbo.DispatchOrder d JOIN dbo.ReliefRequest r ON r.RequestID = d.RequestID
            JOIN dbo.Warehouse w ON w.WarehouseID = d.WarehouseID
            WHERE w.RegionID <> r.RegionID AND NOT (r.RegionID = 19 AND d.WarehouseID = 18);
INSERT #check VALUES ('B11', N'Kho xuất không thuộc vùng của yêu cầu (trừ quy ước vùng 19 -> kho 18)', N'0', @x, IIF(@x = 0, 1, 0));
-- B12 vùng 19 không có kho; vùng 20 không có Pending
SELECT @x = (SELECT COUNT(*) FROM dbo.Warehouse WHERE RegionID = 19)
          + (SELECT COUNT(*) FROM dbo.ReliefRequest WHERE RegionID = 20 AND Status = 'Pending');
INSERT #check VALUES ('B12', N'Kho thuộc vùng 19 + yêu cầu Pending của vùng 20', N'0', @x, IIF(@x = 0, 1, 0));
-- B13 đầu vào tình huống kiểm chứng Ca 2
DECLARE @in NVARCHAR(100) = CONCAT(
    (SELECT CONCAT(RequestedQty, N'/', Status) FROM dbo.ReliefRequest WHERE RequestID = 50000 AND RegionID = 20 AND ItemID = 1), N'|',
    (SELECT SUM(DispatchedQty) FROM dbo.DispatchOrder WHERE RequestID = 50000), N'|',
    (SELECT SUM(Quantity - ReservedQty) FROM dbo.Inventory WHERE ItemID = 1 AND WarehouseID IN (19,20)), N'|',
    (SELECT COUNT(*) FROM dbo.ReliefRequest WHERE RegionID = 20 AND ItemID = 1), N'|',
    (SELECT Unit FROM dbo.Item WHERE ItemID = 1));
INSERT #check VALUES ('B13', N'Đầu vào Ca 2: yêu cầu/trạng thái | đã xuất | khả dụng kho 19+20 | số yêu cầu (R20,I1) | đơn vị',
                      N'100/PartiallyDispatched|40|45|1|Thùng', @in, IIF(@in = N'100/PartiallyDispatched|40|45|1|Thùng', 1, 0));
-- B14 Unit không bị suy ra từ CategoryID (tránh phụ thuộc bắc cầu trong Item)
SELECT @x = COUNT(*) FROM (SELECT CategoryID FROM dbo.Item GROUP BY CategoryID HAVING COUNT(DISTINCT Unit) >= 2) z;
INSERT #check VALUES ('B14', N'Số Category có >= 2 đơn vị tính (CategoryID không xác định Unit)', N'>= 1', @x, IIF(@x >= 1, 1, 0));
-- B15 mức khẩn cấp và tham chiếu AuditLog (không có FK theo C2 nhưng dữ liệu phải hợp lệ)
SELECT @x = (SELECT COUNT(*) FROM dbo.AuditLog a WHERE NOT EXISTS (SELECT 1 FROM dbo.Inventory v WHERE v.WarehouseID = a.WarehouseID AND v.ItemID = a.ItemID))
          + (SELECT COUNT(*) FROM dbo.AuditLog WHERE ActionType NOT IN ('DISPATCHOUT','RECEIVE','RESERVE','ADJUST'));
INSERT #check VALUES ('B15', N'AuditLog trỏ tới cặp kho–vật phẩm không tồn tại / ActionType lạ', N'0', @x, IIF(@x = 0, 1, 0));
GO
