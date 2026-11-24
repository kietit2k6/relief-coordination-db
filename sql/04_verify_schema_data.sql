/* =====================================================================
   04_verify_schema_data.sql
   Chạy toàn bộ kiểm tra cấu trúc + nghiệp vụ (include/business_checks.sql).
   * Mọi mục PASS -> in "##ACCEPTED" và manifest (##MANIFEST|Bảng|Số dòng|SHA-256).
   * Có mục FAIL   -> in danh sách lỗi, KHÔNG in manifest, THROW 50400 (runner dừng).
   Chỉ đọc. Chạy: tools/run_sql.sh 04_verify_schema_data.sql
   ===================================================================== */
USE DisasterReliefDB;
SET NOCOUNT ON;
GO
:r include/business_checks.sql
PRINT N'== V1. Kết quả kiểm tra cấu trúc và nghiệp vụ ==';
SELECT CheckID, Description, Expected, Actual, IIF(Pass = 1, 'PASS', 'FAIL') AS Result FROM #check ORDER BY CheckID;
GO
IF EXISTS (SELECT 1 FROM #check WHERE Pass = 0)
BEGIN
    DECLARE @f NVARCHAR(2000) = (SELECT STRING_AGG(CAST(CheckID AS NVARCHAR(20)), N', ') FROM #check WHERE Pass = 0);
    DECLARE @msg NVARCHAR(2048) = CONCAT(N'các mục FAIL: ', @f);
    THROW 50400, @msg, 1;
END;
GO
PRINT N'== V2. Mã nguồn 1.2: số dòng theo metadata và số trang đã cấp phát ==';
SELECT t.name AS TableName, p.rows AS RowTotal,
       SUM(a.total_pages) AS AllocatedPages,
       CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2)) AS AllocatedMB
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE i.index_id IN (0, 1)
GROUP BY t.name, p.rows ORDER BY p.rows DESC;
GO
PRINT N'== V3. Phân phối ReliefRequest theo vùng x trạng thái (căn cứ chọn vùng nóng/lạnh cho Ca 3) ==';
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
SELECT Status, COUNT_BIG(*) AS Requests, SUM(CAST(RequestedQty AS BIGINT)) AS RequestedQty
FROM dbo.ReliefRequest GROUP BY Status ORDER BY Requests DESC;
GO
:r include/manifest.sql
PRINT N'== V4. Manifest baseline ==';
SELECT * FROM #manifest ORDER BY TableName;
DECLARE @line NVARCHAR(400), @t sysname, @n BIGINT, @h CHAR(64);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TableName, RowsCount, DataSha256 FROM #manifest ORDER BY TableName;
OPEN c; FETCH NEXT FROM c INTO @t, @n, @h;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @line = CONCAT(N'##MANIFEST|', @t, N'|', @n, N'|', @h); PRINT @line;
    FETCH NEXT FROM c INTO @t, @n, @h;
END;
CLOSE c; DEALLOCATE c;
DECLARE @acc NVARCHAR(200) = CONCAT(N'##ACCEPTED|', CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126),
                                    N'|checks=', (SELECT COUNT(*) FROM #check), N'/', (SELECT COUNT(*) FROM #check WHERE Pass = 1));
PRINT @acc;
GO