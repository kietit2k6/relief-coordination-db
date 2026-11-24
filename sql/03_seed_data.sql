/* =====================================================================
   03_seed_data.sql — sinh 261.260 dòng TẤT ĐỊNH (set-based, Tally CTE)
     * Item.Unit KHÔNG còn suy từ CategoryID khiến dữ liệu thể hiện
       phụ thuộc CategoryID -> Unit, trái với khẳng định 3NF của bảng Item). Đơn vị nay chọn theo băm.
   Quy ước:
   * "Ngẫu nhiên" tất định: SHA2_256 trên (tên thuộc tính, số dòng), lấy 6 byte -> BIGINT (luôn >= 0).
   * Mốc thời gian cố định trong năm 2025, không phụ thuộc giờ chạy.
   * ReliefRequest.Status:
       Pending, Approved           – chưa xuất hàng
       PartiallyDispatched         – 0 < tổng xuất < yêu cầu
       Delivered                   – tổng xuất = yêu cầu
       Cancelled                   – không xuất
     "Còn hiệu lực" = Pending, Approved, PartiallyDispatched.
   * Kho theo vùng: kho 1–18 -> vùng 1–18; kho 19, 20 -> vùng 20; kho 21–30 -> vùng 1–10.
     Vùng 19 KHÔNG có kho (Ca 2: vùng có nhu cầu nhưng không có tồn tại chỗ).
   * Tình huống kiểm chứng Ca 2 (nằm trong 261.260 dòng): vùng 20, vật phẩm 1 (Thùng):
       RequestID 50000 yêu cầu 100, đã xuất DispatchID 99999 = 25 và 100000 = 15;
       kho 19: Quantity 30 / Reserved 5, kho 20: 25 / 5 -> khả dụng 25 + 20 = 45.
       Kỳ vọng: còn phải cấp 60, đáp ứng tại chỗ 45, còn thiếu 15. Vùng 20 không có yêu cầu Pending.

   Chạy lại: 9 bảng rỗng -> sinh; đủ đúng số dòng -> bỏ qua; lệch -> THROW (không chèn trùng, không xóa).
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
DECLARE @state TABLE (t sysname, expected BIGINT, actual BIGINT);
INSERT @state
SELECT v.t, v.e, (SELECT SUM(p.rows) FROM sys.partitions p
                  WHERE p.object_id = OBJECT_ID(N'dbo.' + v.t) AND p.index_id IN (0,1))
FROM (VALUES (N'Region',20),(N'Warehouse',30),(N'Category',10),(N'Item',200),(N'Donor',5000),
             (N'Inventory',6000),(N'ReliefRequest',50000),(N'DispatchOrder',100000),(N'AuditLog',100000)) v(t,e);
IF EXISTS (SELECT 1 FROM @state WHERE actual IS NULL)
    THROW 50300, N'Thiếu bảng — chạy 01_schema.sql trước.', 1;
IF NOT EXISTS (SELECT 1 FROM @state WHERE actual <> 0)
    PRINT N'Các bảng rỗng — bắt đầu sinh dữ liệu.';
ELSE IF NOT EXISTS (SELECT 1 FROM @state WHERE actual <> expected)
BEGIN
    PRINT N'Dữ liệu đã đủ 261.260 dòng — bỏ qua bước sinh. Chạy 04_verify_schema_data.sql để kiểm tra.';
    SET NOEXEC ON;
END
ELSE
    THROW 50301, N'Bảng có dữ liệu nhưng số dòng khác thiết kế — dừng để không chèn trùng/xóa nhầm.', 1;
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
 (6,N'Chăn màn, quần áo',0),(7,N'Lều bạt',0),(8,N'Thiết bị chiếu sáng',0),(9,N'Vệ sinh cá nhân',0),
 (10,N'Sữa và dinh dưỡng trẻ em',1);

/* ---------- 4. Item (200): CategoryID = ((ItemID-1) % 10) + 1
   Unit chọn theo băm của ItemID (không phụ thuộc CategoryID); vật phẩm 1 = 'Thùng'. ---------- */
;WITH n AS (SELECT TOP (200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects),
h AS (SELECT i, HASHBYTES('SHA2_256', CONCAT('UNIT#', i)) AS hb FROM n)
INSERT dbo.Item (ItemID, CategoryID, ItemName, Unit, UnitWeight)
SELECT h.i, c.CategoryID,
       CASE WHEN h.i = 1 THEN N'Nước uống đóng chai' ELSE CONCAT(c.CategoryName, N' - mã ', FORMAT(h.i, '000')) END,
       CASE WHEN h.i = 1 THEN N'Thùng'
            ELSE CHOOSE(CAST(SUBSTRING(h.hb,1,6) AS BIGINT) % 9 + 1,
                        N'Thùng', N'Bao', N'Kg', N'Hộp', N'Bộ', N'Chiếc', N'Gói', N'Chai', N'Túi') END,
       CAST(0.25 + (h.i * 37 % 400) / 10.0 AS DECIMAL(8,2))
FROM h JOIN dbo.Category c ON c.CategoryID = ((h.i - 1) % 10) + 1;

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
   Vùng (phần nghìn): R1 250, R2 150, R3 100, R4–R15 mỗi vùng 40, R16–R20 mỗi vùng 4.
   Vật phẩm: 50% rơi vào 20 vật phẩm phổ biến (1–20), 50% rải đều 21–200.
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
       CASE WHEN RegionID = 20 AND ItemID0 = 1 THEN 2 ELSE ItemID0 END,   -- dành (vùng 20, vật phẩm 1) cho tình huống kiểm chứng
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
   Chỉ yêu cầu Delivered / PartiallyDispatched có dòng xuất; k = base hoặc base+1 dòng mỗi yêu cầu
   sao cho tổng đúng 99.998. Delivered: tổng xuất = yêu cầu; PartiallyDispatched: 30–80% yêu cầu.
   Vật phẩm xuất = vật phẩm yêu cầu (C6); kho xuất thuộc vùng của yêu cầu (vùng 19 dùng kho 18);
   DispatchedAt = CreatedAt + j*6 giờ + 0..299 phút. */
DECLARE @nDisp INT = (SELECT COUNT(*) FROM dbo.ReliefRequest
                      WHERE Status IN ('Delivered','PartiallyDispatched') AND RequestID < 50000);
DECLARE @base INT = 99998 / @nDisp, @rem INT = 99998 % @nDisp;
;WITH rw AS (
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
    SELECT rk.*, j.j, HASHBYTES('SHA2_256', CONCAT('DSPL#', rk.RequestID, '#', j.j)) AS hl
    FROM rk JOIN (VALUES (1),(2),(3),(4),(5),(6),(7),(8)) j(j) ON j.j <= rk.k)
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
IF (SELECT COUNT(*) FROM #disp) <> 99998 THROW 50302, N'Sinh DispatchOrder không đủ 99.998 dòng.', 1;
SET IDENTITY_INSERT dbo.DispatchOrder ON;
INSERT dbo.DispatchOrder (DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt)
SELECT DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt FROM #disp;
INSERT dbo.DispatchOrder (DispatchID, RequestID, WarehouseID, ItemID, DonorID, DispatchedQty, DispatchedAt) VALUES
 (99999,  50000, 19, 1, 1,    25, '2025-10-16T09:00:00'),
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
/* Statistics FULLSCAN để plan của lab tái lập được giữa các lần cài đặt */
UPDATE STATISTICS dbo.Region WITH FULLSCAN;        UPDATE STATISTICS dbo.Warehouse WITH FULLSCAN;
UPDATE STATISTICS dbo.Category WITH FULLSCAN;      UPDATE STATISTICS dbo.Item WITH FULLSCAN;
UPDATE STATISTICS dbo.Donor WITH FULLSCAN;         UPDATE STATISTICS dbo.Inventory WITH FULLSCAN;
UPDATE STATISTICS dbo.ReliefRequest WITH FULLSCAN; UPDATE STATISTICS dbo.DispatchOrder WITH FULLSCAN;
UPDATE STATISTICS dbo.AuditLog WITH FULLSCAN;
PRINT N'Đã cập nhật statistics FULLSCAN.';
GO
SET NOEXEC OFF;
GO
