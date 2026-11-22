/* =====================================================================
   02_seed_data.sql — sinh 261.260 dòng tất định (set-based, Tally CTE)
   Quy ước:
   * "Ngẫu nhiên" tất định: hàm băm SHA2_256 trên (tên thuộc tính, số dòng),
     lấy 6 byte đầu đổi sang BIGINT (luôn >= 0, không cần ABS).
   * Mốc thời gian cố định: năm 2025 (không phụ thuộc giờ chạy).
   * Trạng thái yêu cầu (ReliefRequest.Status):
       Pending             – chờ duyệt, CHƯA xuất hàng
       Approved            – đã duyệt, CHƯA xuất hàng
       PartiallyDispatched – đã xuất một phần (0 < tổng xuất < yêu cầu)
       Delivered           – đã xuất đủ (tổng xuất = yêu cầu)
       Cancelled           – đã hủy, không xuất hàng
     "Còn hiệu lực" (còn phải cấp) = Pending, Approved, PartiallyDispatched.
   * Kho theo vùng (Warehouse.RegionID): kho 1–18 -> vùng 1–18; kho 19, 20 ->
     vùng 20; kho 21–30 -> vùng 1–10. Vùng 19 KHÔNG có kho (để Ca 2 có
     trường hợp vùng có nhu cầu nhưng không có dòng tồn tại chỗ).
   * Tình huống kiểm chứng Ca 2 (nằm trong seed, tổng vẫn 261.260):
       vùng 20 (Lai Châu), vật phẩm 1 (Nước uống đóng chai, Thùng):
       RequestID 50000 yêu cầu 100, đã xuất DispatchID 99999 = 25 và
       100000 = 15; kho 19 khả dụng 25, kho 20 khả dụng 20 (tổng 45).
       Kỳ vọng: còn phải cấp 60, đáp ứng tại chỗ 45, còn thiếu 15.
       Vùng 20 không có yêu cầu Pending nào (để thủ tục báo cáo vùng
       khẩn cấp có trường hợp "chưa có yêu cầu chờ").
   Chạy lại: nếu 9 bảng đã đủ đúng số dòng -> bỏ qua; nếu có dữ liệu lệch -> dừng.
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
DECLARE @state TABLE (t sysname, expected BIGINT, actual BIGINT);
INSERT @state
SELECT v.t, v.e, p.rows
FROM (VALUES (N'Region',20),(N'Warehouse',30),(N'Category',10),(N'Item',200),(N'Donor',5000),
             (N'Inventory',6000),(N'ReliefRequest',50000),(N'DispatchOrder',100000),(N'AuditLog',100000)) v(t,e)
CROSS APPLY (SELECT SUM(p.rows) AS rows FROM sys.partitions p
             WHERE p.object_id = OBJECT_ID(N'dbo.' + v.t) AND p.index_id IN (0,1)) p;
IF NOT EXISTS (SELECT 1 FROM @state WHERE actual <> 0)
    PRINT N'Các bảng rỗng — bắt đầu sinh dữ liệu.';
ELSE IF NOT EXISTS (SELECT 1 FROM @state WHERE actual <> expected)
BEGIN
    PRINT N'Dữ liệu seed đã đủ (261.260 dòng) — bỏ qua bước sinh, chỉ chạy kiểm tra.';
    SET NOEXEC ON;  -- bỏ qua các batch sinh dữ liệu, tới nhãn kiểm tra sẽ bật lại
END
ELSE
    THROW 50010, N'Bảng có dữ liệu nhưng số dòng khác thiết kế — dừng để không chèn trùng/xóa nhầm.', 1;
GO
BEGIN TRANSACTION;

/* ---------- 1. Region (20) ---------- */
INSERT dbo.Region (RegionID, RegionName, SeverityLevel, AffectedPop) VALUES
 (1,N'Quảng Trị',5,182000),(2,N'Quảng Bình',5,151000),(3,N'Hà Tĩnh',4,98000),(4,N'Nghệ An',4,87000),
 (5,N'Thừa Thiên Huế',4,76000),(6,N'Quảng Nam',3,64000),(7,N'Quảng Ngãi',3,52000),(8,N'Bình Định',2,31000),
 (9,N'Phú Yên',2,27000),(10,N'Khánh Hòa',2,22000),(11,N'Thanh Hóa',3,45000),(12,N'Yên Bái',4,39000),
 (13,N'Lào Cai',4,41000),(14,N'Hà Giang',3,28000),(15,N'Cao Bằng',2,19000),(16,N'Bắc Kạn',1,8000),
 (17,N'Tuyên Quang',2,12000),(18,N'Sơn La',3,17000),(19,N'Điện Biên',4,15000),(20,N'Lai Châu',5,21000);

/* ---------- 2. Warehouse (30) ---------- */
;WITH n AS (SELECT TOP (30) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS w FROM sys.all_objects)
INSERT dbo.Warehouse (WarehouseID, RegionID, WarehouseName, Capacity)
SELECT w,
       CASE WHEN w <= 18 THEN w WHEN w IN (19,20) THEN 20 ELSE w - 20 END,
       CONCAT(N'Kho ', r.RegionName, N' ', CASE WHEN w <= 20 THEN N'số 1' ELSE N'số 2' END,
              CASE WHEN w = 20 THEN N'B' ELSE N'' END),
       50000 + (w * 7919) % 50000
FROM n JOIN dbo.Region r ON r.RegionID = CASE WHEN w <= 18 THEN w WHEN w IN (19,20) THEN 20 ELSE w - 20 END;

/* ---------- 3. Category (10) ---------- */
INSERT dbo.Category (CategoryID, CategoryName, IsPerishable) VALUES
 (1,N'Nước uống',0),(2,N'Lương thực khô',0),(3,N'Thực phẩm tươi',1),(4,N'Thuốc men',1),(5,N'Vật tư y tế',0),
 (6,N'Chăn màn, quần áo',0),(7,N'Lều bạt',0),(8,N'Thiết bị chiếu sáng',0),(9,N'Vệ sinh cá nhân',0),(10,N'Sữa và dinh dưỡng trẻ em',1);

/* ---------- 4. Item (200): CategoryID = ((ItemID-1) % 10) + 1 ---------- */
;WITH n AS (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
INSERT dbo.Item (ItemID, CategoryID, ItemName, Unit, UnitWeight)
SELECT i, c.CategoryID,
       CASE WHEN i = 1 THEN N'Nước uống đóng chai' ELSE CONCAT(c.CategoryName, N' - mã ', FORMAT(i, '000')) END,
       CHOOSE(c.CategoryID, N'Thùng', N'Bao', N'Kg', N'Hộp', N'Bộ', N'Chiếc', N'Bộ', N'Chiếc', N'Gói', N'Hộp'),
       CAST(0.25 + (i * 37 % 400) / 10.0 AS DECIMAL(8,2))
FROM n JOIN dbo.Category c ON c.CategoryID = ((i - 1) % 10) + 1;

/* ---------- 5. Donor (5.000) ---------- */
;WITH n AS (SELECT TOP (5000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS d
            FROM sys.all_objects a CROSS JOIN sys.all_objects b),
h AS (SELECT d, HASHBYTES('SHA2_256', CONCAT('DONOR#', d)) AS hb FROM n)
INSERT dbo.Donor (DonorID, DonorName, DonorType, Phone)
SELECT d,
       CONCAT(CHOOSE(CAST(SUBSTRING(hb,1,6) AS BIGINT) % 8 + 1, N'Nguyễn', N'Trần', N'Lê', N'Phạm', N'Hoàng', N'Huỳnh', N'Võ', N'Đặng'),
              N' ', CHOOSE(CAST(SUBSTRING(hb,7,6) AS BIGINT) % 6 + 1, N'Văn', N'Thị', N'Minh', N'Thanh', N'Quốc', N'Hữu'),
              N' ', CHOOSE(CAST(SUBSTRING(hb,13,6) AS BIGINT) % 8 + 1, N'An', N'Bình', N'Chi', N'Dũng', N'Hà', N'Khoa', N'Lan', N'Nam'),
              N' ', FORMAT(d, '00000')),
       CASE WHEN CAST(SUBSTRING(hb,19,6) AS BIGINT) % 10 < 6 THEN 'Individual'
            WHEN CAST(SUBSTRING(hb,19,6) AS BIGINT) % 10 < 9 THEN 'Organization' ELSE 'Government' END,
       CONCAT('09', FORMAT(CAST(SUBSTRING(hb,25,6) AS BIGINT) % 100000000, '00000000'))
FROM h;

/* ---------- 6. Inventory (6.000 = 30 kho x 200 vật phẩm) ---------- */
;WITH g AS (SELECT w.WarehouseID, i.ItemID,
                   HASHBYTES('SHA2_256', CONCAT('INV#', w.WarehouseID, '#', i.ItemID)) AS hb
            FROM dbo.Warehouse w CROSS JOIN dbo.Item i),
q AS (SELECT WarehouseID, ItemID,
             CAST(CAST(SUBSTRING(hb,1,6) AS BIGINT) % 2000 AS INT) AS Qty,
             CAST(CAST(SUBSTRING(hb,7,6) AS BIGINT) % 30 AS INT) AS ResPct
      FROM g)
INSERT dbo.Inventory (WarehouseID, ItemID, Quantity, ReservedQty, UpdatedAt)
SELECT WarehouseID, ItemID,
       CASE WHEN ItemID = 1 AND WarehouseID = 19 THEN 30
            WHEN ItemID = 1 AND WarehouseID = 20 THEN 25 ELSE Qty END,
       CASE WHEN ItemID = 1 AND WarehouseID IN (19,20) THEN 5 ELSE Qty * ResPct / 100 END,
       '2025-12-31T23:00:00'
FROM q;

/* ---------- 7. ReliefRequest (49.999 sinh + 1 tình huống kiểm chứng) ----------
   Phân bố vùng (phần nghìn): R1 250, R2 150, R3 100, R4–R15 mỗi vùng 40, R16–R20 mỗi vùng 4.
   Vật phẩm: 50% rơi vào 20 vật phẩm phổ biến (1–20), 50% còn lại rải đều 21–200.
   Trạng thái (%): Delivered 70, PartiallyDispatched 10, Approved 7, Pending 5, Cancelled 8. */
SET IDENTITY_INSERT dbo.ReliefRequest ON;
;WITH n AS (SELECT TOP (49999) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rid
            FROM sys.all_objects a CROSS JOIN sys.all_objects b),
h AS (SELECT rid, HASHBYTES('SHA2_256', CONCAT('REQ#', rid)) AS hb FROM n),
x AS (SELECT rid,
             CAST(SUBSTRING(hb, 1,6) AS BIGINT) % 1000 AS rr,
             CAST(SUBSTRING(hb, 7,6) AS BIGINT) % 1000 AS ii,
             CAST(SUBSTRING(hb,13,6) AS BIGINT) % 100  AS ss,
             CAST(SUBSTRING(hb,19,6) AS BIGINT) % 491  AS qq,
             CAST(SUBSTRING(hb,25,6) AS BIGINT) % 525600 AS mm   -- phút trong năm 2025
      FROM h),
y AS (SELECT rid, qq, mm, ss,
             CASE WHEN rr < 250 THEN 1 WHEN rr < 400 THEN 2 WHEN rr < 500 THEN 3
                  WHEN rr < 980 THEN 4 + (rr - 500) / 40
                  ELSE 16 + (rr - 980) / 4 END AS RegionID,
             CASE WHEN ii < 500 THEN ii / 25 + 1 ELSE 21 + (ii - 500) % 180 END AS ItemID0
      FROM x)
INSERT dbo.ReliefRequest (RequestID, RegionID, ItemID, RequestedQty, Status, CreatedAt)
SELECT rid, RegionID,
       CASE WHEN RegionID = 20 AND ItemID0 = 1 THEN 2 ELSE ItemID0 END,           -- dành (vùng 20, vật phẩm 1) cho tình huống kiểm chứng
       10 + qq,
       CASE WHEN ss < 70 THEN 'Delivered' WHEN ss < 80 THEN 'PartiallyDispatched'
            WHEN ss < 87 THEN 'Approved'
            WHEN ss < 92 THEN CASE WHEN RegionID = 20 THEN 'Approved' ELSE 'Pending' END  -- vùng 20 không có Pending
            ELSE 'Cancelled' END,
       DATEADD(MINUTE, mm, CAST('2025-01-01T00:00:00' AS DATETIME2))
FROM y;
INSERT dbo.ReliefRequest (RequestID, RegionID, ItemID, RequestedQty, Status, CreatedAt)
VALUES (50000, 20, 1, 100, 'PartiallyDispatched', '2025-10-15T08:00:00');
SET IDENTITY_INSERT dbo.ReliefRequest OFF;

/* ---------- 8. DispatchOrder (99.998 sinh + 2 tình huống kiểm chứng) ----------
   Chỉ yêu cầu Delivered / PartiallyDispatched có dòng xuất. Số dòng xuất mỗi yêu cầu
   k = base hoặc base+1 sao cho tổng đúng 99.998. Delivered: tổng xuất = yêu cầu;
   PartiallyDispatched: tổng xuất = 30–80% yêu cầu (luôn < yêu cầu, >= k).
   Vật phẩm xuất = vật phẩm yêu cầu; kho xuất = kho trong vùng (vùng 19 dùng kho 18);
   DispatchedAt = CreatedAt + j*6 giờ + 0..299 phút (luôn sau CreatedAt). */
DECLARE @nDisp INT = (SELECT COUNT(*) FROM dbo.ReliefRequest
                      WHERE Status IN ('Delivered','PartiallyDispatched') AND RequestID < 50000);
DECLARE @base INT = 99998 / @nDisp, @rem INT = 99998 % @nDisp;

;WITH rw AS (   -- danh sách kho theo vùng, đánh số trong vùng
    SELECT RegionID, WarehouseID, ROW_NUMBER() OVER (PARTITION BY RegionID ORDER BY WarehouseID) AS slot,
           COUNT(*) OVER (PARTITION BY RegionID) AS cnt
    FROM dbo.Warehouse),
rq AS (
    SELECT r.RequestID, r.RegionID, r.ItemID, r.RequestedQty, r.Status, r.CreatedAt,
           ROW_NUMBER() OVER (ORDER BY r.RequestID) AS rn,
           HASHBYTES('SHA2_256', CONCAT('DSP#', r.RequestID)) AS hb
    FROM dbo.ReliefRequest r
    WHERE r.Status IN ('Delivered','PartiallyDispatched') AND r.RequestID < 50000),
rk AS (
    SELECT rq.*, @base + CASE WHEN rn <= @rem THEN 1 ELSE 0 END AS k,
           CASE WHEN Status = 'Delivered' THEN RequestedQty
                ELSE RequestedQty * (30 + CAST(SUBSTRING(hb,1,6) AS BIGINT) % 51) / 100 END AS total
    FROM rq),
lines AS (
    SELECT rk.*, j.j,
           HASHBYTES('SHA2_256', CONCAT('DSPL#', rk.RequestID, '#', j.j)) AS hl
    FROM rk
    JOIN (VALUES (1),(2),(3),(4),(5),(6),(7),(8)) j(j) ON j.j <= rk.k)
SELECT ROW_NUMBER() OVER (ORDER BY l.RequestID, l.j) AS DispatchID,
       l.RequestID,
       COALESCE(w.WarehouseID, 18) AS WarehouseID,
       l.ItemID,
       CASE WHEN CAST(SUBSTRING(l.hl,1,6) AS BIGINT) % 10 = 0 THEN NULL
            ELSE CAST(CAST(SUBSTRING(l.hl,7,6) AS BIGINT) % 5000 + 1 AS INT) END AS DonorID,
       l.total / l.k + CASE WHEN l.j <= l.total % l.k THEN 1 ELSE 0 END AS DispatchedQty,
       DATEADD(MINUTE, l.j * 360 + CAST(SUBSTRING(l.hl,13,6) AS BIGINT) % 300, l.CreatedAt) AS DispatchedAt
INTO #disp
FROM lines l
OUTER APPLY (SELECT TOP (1) rw.WarehouseID FROM rw
             WHERE rw.RegionID = l.RegionID
               AND rw.slot = CAST(SUBSTRING(l.hl,19,6) AS BIGINT) % rw.cnt + 1) w;

IF (SELECT COUNT(*) FROM #disp) <> 99998 THROW 50011, N'Sinh DispatchOrder không đủ 99.998 dòng.', 1;

SET IDENTITY_INSERT dbo.DispatchOrder ON;
INSERT dbo.DispatchOrder (DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt)
SELECT DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt FROM #disp;
INSERT dbo.DispatchOrder (DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt) VALUES
 (99999, 50000, 19, 1, 1, 25, '2025-10-16T09:00:00'),
 (100000, 50000, 20, 1, NULL, 15, '2025-10-18T14:30:00');
SET IDENTITY_INSERT dbo.DispatchOrder OFF;
DROP TABLE #disp;

/* ---------- 9. AuditLog (100.000) ---------- */
SET IDENTITY_INSERT dbo.AuditLog ON;
;WITH n AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS lid
            FROM sys.all_objects a CROSS JOIN sys.all_objects b),
h AS (SELECT lid, HASHBYTES('SHA2_256', CONCAT('LOG#', lid)) AS hb FROM n),
x AS (SELECT lid,
             CAST(SUBSTRING(hb, 1,6) AS BIGINT) % 30 + 1   AS WarehouseID,
             CAST(SUBSTRING(hb, 7,6) AS BIGINT) % 200 + 1  AS ItemID,
             CAST(SUBSTRING(hb,13,6) AS BIGINT) % 100      AS aa,
             CAST(SUBSTRING(hb,19,6) AS BIGINT) % 300 + 1  AS qty,
             CAST(SUBSTRING(hb,25,6) AS BIGINT) % 525600   AS mm
      FROM h)
INSERT dbo.AuditLog (LogID, WarehouseID, ItemID, ActionType, DeltaQty, LoggedAt)
SELECT lid, WarehouseID, ItemID,
       CASE WHEN aa < 40 THEN 'DISPATCHOUT' WHEN aa < 70 THEN 'RECEIVE' WHEN aa < 85 THEN 'RESERVE' ELSE 'ADJUST' END,
       CASE WHEN aa < 40 THEN -qty WHEN aa < 70 THEN qty WHEN aa < 85 THEN -qty
            ELSE CASE WHEN qty % 2 = 0 THEN qty / 10 + 1 ELSE -(qty / 10 + 1) END END,
       DATEADD(MINUTE, mm, CAST('2025-01-01T00:00:00' AS DATETIME2))
FROM x;
SET IDENTITY_INSERT dbo.AuditLog OFF;

COMMIT TRANSACTION;
PRINT N'Đã sinh dữ liệu.';
GO
SET NOEXEC OFF;
GO
/* =====================================================================
   Cập nhật statistics + KIỂM TRA (chạy cả khi bỏ qua bước sinh)
   ===================================================================== */
UPDATE STATISTICS dbo.Region WITH FULLSCAN;      UPDATE STATISTICS dbo.Warehouse WITH FULLSCAN;
UPDATE STATISTICS dbo.Category WITH FULLSCAN;    UPDATE STATISTICS dbo.Item WITH FULLSCAN;
UPDATE STATISTICS dbo.Donor WITH FULLSCAN;       UPDATE STATISTICS dbo.Inventory WITH FULLSCAN;
UPDATE STATISTICS dbo.ReliefRequest WITH FULLSCAN; UPDATE STATISTICS dbo.DispatchOrder WITH FULLSCAN;
UPDATE STATISTICS dbo.AuditLog WITH FULLSCAN;
GO
PRINT N'== K1. Mã nguồn 1.2: số dòng theo metadata và số trang của heap/clustered index ==';
SELECT t.name AS TableName, p.rows AS RowTotal,
       SUM(a.total_pages) AS AllocatedPages,
       CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2)) AS AllocatedMB
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE i.index_id IN (0, 1) AND SCHEMA_NAME(t.schema_id) = N'dbo'
GROUP BY t.name, p.rows ORDER BY p.rows DESC;
GO
PRINT N'== K2. COUNT_BIG từng bảng, số cột và tổng ==';
DECLARE @c TABLE (TableName sysname, Expected BIGINT, Actual BIGINT, Cols INT);
INSERT @c SELECT N'Region',20,(SELECT COUNT_BIG(*) FROM dbo.Region),0
UNION ALL SELECT N'Warehouse',30,(SELECT COUNT_BIG(*) FROM dbo.Warehouse),0
UNION ALL SELECT N'Category',10,(SELECT COUNT_BIG(*) FROM dbo.Category),0
UNION ALL SELECT N'Item',200,(SELECT COUNT_BIG(*) FROM dbo.Item),0
UNION ALL SELECT N'Donor',5000,(SELECT COUNT_BIG(*) FROM dbo.Donor),0
UNION ALL SELECT N'Inventory',6000,(SELECT COUNT_BIG(*) FROM dbo.Inventory),0
UNION ALL SELECT N'ReliefRequest',50000,(SELECT COUNT_BIG(*) FROM dbo.ReliefRequest),0
UNION ALL SELECT N'DispatchOrder',100000,(SELECT COUNT_BIG(*) FROM dbo.DispatchOrder),0
UNION ALL SELECT N'AuditLog',100000,(SELECT COUNT_BIG(*) FROM dbo.AuditLog),0;
UPDATE c SET Cols = (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.' + c.TableName)) FROM @c c;
SELECT TableName, Expected, Actual, Cols FROM @c
UNION ALL SELECT N'TỔNG', SUM(Expected), SUM(Actual), SUM(Cols) FROM @c;
IF EXISTS (SELECT 1 FROM @c WHERE Expected <> Actual) OR (SELECT SUM(Actual) FROM @c) <> 261260
    THROW 50020, N'Số dòng không khớp Bảng 1.2.', 1;
IF (SELECT SUM(Cols) FROM @c) <> 44 THROW 50021, N'Số cột khác 44.', 1;
GO
PRINT N'== K3. FK/CHECK: không có ràng buộc bị tắt hoặc untrusted; DBCC CHECKCONSTRAINTS ==';
SELECT name, type_desc, is_disabled, is_not_trusted FROM (
    SELECT name, type_desc, is_disabled, is_not_trusted FROM sys.foreign_keys
    UNION ALL SELECT name, type_desc, is_disabled, is_not_trusted FROM sys.check_constraints) x
WHERE is_disabled = 1 OR is_not_trusted = 1;
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1)
   OR EXISTS (SELECT 1 FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1)
    THROW 50022, N'Có FK/CHECK bị tắt hoặc untrusted.', 1;
DBCC CHECKCONSTRAINTS WITH ALL_CONSTRAINTS, NO_INFOMSGS;
SELECT (SELECT COUNT(*) FROM sys.foreign_keys WHERE SCHEMA_NAME(schema_id) = N'dbo') AS ForeignKeys_dbo,
       (SELECT COUNT(*) FROM sys.check_constraints WHERE SCHEMA_NAME(schema_id) = N'dbo') AS CheckConstraints_dbo;
GO
PRINT N'== K4. Quy tắc nghiệp vụ của DispatchOrder ==';
DECLARE @itemMismatch INT, @timeBad INT, @dispOnWrongStatus INT, @delivBad INT, @partBad INT, @overDisp INT, @noDispOnDone INT;
SELECT @itemMismatch = COUNT(*) FROM dbo.DispatchOrder d JOIN dbo.ReliefRequest r ON r.RequestID = d.RequestID WHERE d.ItemID <> r.ItemID;
SELECT @timeBad = COUNT(*) FROM dbo.DispatchOrder d JOIN dbo.ReliefRequest r ON r.RequestID = d.RequestID WHERE d.DispatchedAt < r.CreatedAt;
;WITH s AS (SELECT RequestID, SUM(DispatchedQty) AS Disp FROM dbo.DispatchOrder GROUP BY RequestID)
SELECT @dispOnWrongStatus = SUM(CASE WHEN r.Status IN ('Pending','Approved','Cancelled') AND s.Disp IS NOT NULL THEN 1 ELSE 0 END),
       @delivBad          = SUM(CASE WHEN r.Status = 'Delivered' AND ISNULL(s.Disp,0) <> r.RequestedQty THEN 1 ELSE 0 END),
       @partBad           = SUM(CASE WHEN r.Status = 'PartiallyDispatched' AND NOT (ISNULL(s.Disp,0) > 0 AND ISNULL(s.Disp,0) < r.RequestedQty) THEN 1 ELSE 0 END),
       @overDisp          = SUM(CASE WHEN s.Disp > r.RequestedQty THEN 1 ELSE 0 END)
FROM dbo.ReliefRequest r LEFT JOIN s ON s.RequestID = r.RequestID;
SELECT @itemMismatch AS ItemMismatch, @timeBad AS DispatchBeforeCreate, @dispOnWrongStatus AS DispatchOnNonDispatchStatus,
       @delivBad AS DeliveredNotFull, @partBad AS PartialOutOfRange, @overDisp AS OverDispatched;
IF @itemMismatch + @timeBad + @dispOnWrongStatus + @delivBad + @partBad + @overDisp <> 0
    THROW 50023, N'Dữ liệu xuất kho vi phạm quy ước trạng thái.', 1;
GO
PRINT N'== K5. Trạng thái thực tế trong dữ liệu ==';
SELECT Status, COUNT_BIG(*) AS Requests, SUM(CAST(RequestedQty AS BIGINT)) AS RequestedQty
FROM dbo.ReliefRequest GROUP BY Status ORDER BY Requests DESC;
GO
PRINT N'== K6. Phân phối theo RegionID x Status (dùng để chọn tham số đo) ==';
SELECT r.RegionID, g.RegionName, g.SeverityLevel,
       COUNT_BIG(*) AS Total,
       SUM(CASE WHEN Status = 'Pending' THEN 1 ELSE 0 END) AS Pending,
       SUM(CASE WHEN Status = 'Pending' AND CreatedAt >= '2025-03-01' AND CreatedAt < '2025-09-01' THEN 1 ELSE 0 END) AS Pending_Mar_Aug,
       SUM(CASE WHEN Status = 'Approved' THEN 1 ELSE 0 END) AS Approved,
       SUM(CASE WHEN Status = 'PartiallyDispatched' THEN 1 ELSE 0 END) AS Partial,
       SUM(CASE WHEN Status = 'Delivered' THEN 1 ELSE 0 END) AS Delivered,
       SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END) AS Cancelled,
       (SELECT COUNT(*) FROM dbo.Warehouse w WHERE w.RegionID = r.RegionID) AS Warehouses
FROM dbo.ReliefRequest r JOIN dbo.Region g ON g.RegionID = r.RegionID
GROUP BY r.RegionID, g.RegionName, g.SeverityLevel ORDER BY r.RegionID;
GO
PRINT N'== K7. Cặp (kho, vật phẩm) có nhiều lượt xuất nhất (dùng cho demo phân trang) ==';
SELECT TOP (5) WarehouseID, ItemID, COUNT_BIG(*) AS Dispatches
FROM dbo.DispatchOrder GROUP BY WarehouseID, ItemID ORDER BY Dispatches DESC, WarehouseID, ItemID;
GO
PRINT N'== K8. Tình huống kiểm chứng Ca 2 (vùng 20, vật phẩm 1) ==';
SELECT r.RequestID, r.RegionID, r.ItemID, r.RequestedQty, r.Status,
       (SELECT STRING_AGG(CONCAT(d.DispatchID, N':', d.DispatchedQty), N', ') FROM dbo.DispatchOrder d WHERE d.RequestID = r.RequestID) AS Dispatches,
       (SELECT SUM(i.Quantity - i.ReservedQty) FROM dbo.Inventory i JOIN dbo.Warehouse w ON w.WarehouseID = i.WarehouseID
        WHERE w.RegionID = 20 AND i.ItemID = 1) AS LocalAvailable
FROM dbo.ReliefRequest r WHERE r.RegionID = 20 AND r.ItemID = 1;
GO
