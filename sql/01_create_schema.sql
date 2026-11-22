/* =====================================================================
   01_create_schema.sql — DisasterReliefDB (SQL Server 2025, compat 170)
   - Tạo database, 9 bảng / 44 cột theo Hình 1.4 + Mã nguồn 1.1.
   - Baseline: CHỈ có index phục vụ khóa chính (clustered PK). Không tạo
     index phụ (hai index của báo cáo được tạo trong 04_lab_indexing.sql).
   - Hạ tầng đo của lab nằm trong schema [lab] (bảng số đo, harness,
     thủ tục so sánh kết quả, thủ tục reset). Object thí nghiệm nằm trong
     schema [exp] và bị xóa bởi lab.usp_ResetLab / 09_cleanup_reset.sql.
   - Chạy lại an toàn: chỉ tạo object còn thiếu; DỪNG nếu database có
     bảng/dữ liệu ngoài dự kiến.
   Chạy: sqlcmd -C -b -S localhost -U sa -i 01_create_schema.sql
   ===================================================================== */
SET NOCOUNT ON;
IF DB_ID(N'DisasterReliefDB') IS NULL
BEGIN
    CREATE DATABASE DisasterReliefDB;
    PRINT N'Đã tạo database DisasterReliefDB.';
END
ELSE PRINT N'Database DisasterReliefDB đã tồn tại — kiểm tra cấu trúc trước khi dùng lại.';
GO
USE DisasterReliefDB;
GO
/* ---------- Chốt an toàn: chỉ chấp nhận database rỗng hoặc đúng lược đồ dự án ---------- */
DECLARE @expected TABLE (name sysname PRIMARY KEY);
INSERT @expected VALUES (N'Region'),(N'Warehouse'),(N'Category'),(N'Item'),(N'Donor'),
                        (N'Inventory'),(N'ReliefRequest'),(N'DispatchOrder'),(N'AuditLog');
DECLARE @unexpected nvarchar(max) =
   (SELECT STRING_AGG(CONCAT(s.name, N'.', t.name), N', ')
    FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND NOT (s.name = N'dbo' AND t.name IN (SELECT name FROM @expected))
      AND s.name NOT IN (N'lab', N'exp'));
IF @unexpected IS NOT NULL
    THROW 50001, N'DisasterReliefDB chứa bảng ngoài dự kiến — dừng để không ghi đè dữ liệu.', 1;

DECLARE @present int = (SELECT COUNT(*) FROM sys.tables t
                        WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND t.name IN (SELECT name FROM @expected));
IF @present NOT IN (0, 9)
    THROW 50002, N'Chỉ có một phần trong 9 bảng — trạng thái dở dang, cần kiểm tra thủ công.', 1;
IF @present = 9
BEGIN
    DECLARE @cols int = (SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id
                         WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND t.name IN (SELECT name FROM @expected));
    IF @cols <> 44
        THROW 50003, N'9 bảng đã có nhưng số cột khác 44 — lược đồ không khớp báo cáo.', 1;
    PRINT N'9 bảng / 44 cột đã tồn tại — bỏ qua bước tạo bảng.';
END
GO
/* ---------- Cấu hình database cho lab ---------- */
ALTER DATABASE DisasterReliefDB SET RECOVERY FULL;
ALTER DATABASE DisasterReliefDB SET COMPATIBILITY_LEVEL = 170;
ALTER DATABASE DisasterReliefDB SET QUERY_STORE = ON;
ALTER DATABASE DisasterReliefDB SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = ALL,            -- lab: ghi mọi truy vấn để 08 có đủ dữ liệu
    INTERVAL_LENGTH_MINUTES = 5,
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    MAX_STORAGE_SIZE_MB = 1024,
    SIZE_BASED_CLEANUP_MODE = AUTO);
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
-- Kiểm soát nhiễu đo: CE feedback (IQP) tự biên dịch lại plan sau vài lần chạy khi ước lượng
-- lệch, làm số đo lặp lại đổi plan giữa chừng. Tắt trong DB lab (xem RESULTS.md, mục Môi trường).
ALTER DATABASE SCOPED CONFIGURATION SET CE_FEEDBACK = OFF;
ALTER DATABASE SCOPED CONFIGURATION SET CE_FEEDBACK_FOR_EXPRESSIONS = OFF;
GO
/* ---------- 9 bảng (thứ tự theo phụ thuộc khóa ngoại) ---------- */
IF OBJECT_ID(N'dbo.Region') IS NULL
CREATE TABLE dbo.Region (
    RegionID      INT           NOT NULL CONSTRAINT PKRegion PRIMARY KEY CLUSTERED,
    RegionName    NVARCHAR(100) NOT NULL,
    SeverityLevel TINYINT       NOT NULL CONSTRAINT CKRegionSeverity CHECK (SeverityLevel BETWEEN 1 AND 5),
    AffectedPop   INT           NOT NULL CONSTRAINT CKRegionAffectedPop CHECK (AffectedPop >= 0)
);
IF OBJECT_ID(N'dbo.Warehouse') IS NULL
CREATE TABLE dbo.Warehouse (
    WarehouseID   INT           NOT NULL CONSTRAINT PKWarehouse PRIMARY KEY CLUSTERED,
    RegionID      INT           NOT NULL CONSTRAINT FKWarehouseRegion REFERENCES dbo.Region(RegionID),
    WarehouseName NVARCHAR(100) NOT NULL,
    Capacity      INT           NOT NULL CONSTRAINT CKWarehouseCapacity CHECK (Capacity > 0)
);
IF OBJECT_ID(N'dbo.Category') IS NULL
CREATE TABLE dbo.Category (
    CategoryID    INT          NOT NULL CONSTRAINT PKCategory PRIMARY KEY CLUSTERED,
    CategoryName  NVARCHAR(80) NOT NULL,
    IsPerishable  BIT          NOT NULL
);
IF OBJECT_ID(N'dbo.Item') IS NULL
CREATE TABLE dbo.Item (
    ItemID        INT           NOT NULL CONSTRAINT PKItem PRIMARY KEY CLUSTERED,
    CategoryID    INT           NOT NULL CONSTRAINT FKItemCategory REFERENCES dbo.Category(CategoryID),
    ItemName      NVARCHAR(100) NOT NULL,
    Unit          NVARCHAR(20)  NOT NULL,
    UnitWeight    DECIMAL(8,2)  NOT NULL CONSTRAINT CKItemUnitWeight CHECK (UnitWeight > 0)
);
IF OBJECT_ID(N'dbo.Donor') IS NULL
CREATE TABLE dbo.Donor (
    DonorID       INT           NOT NULL CONSTRAINT PKDonor PRIMARY KEY CLUSTERED,
    DonorName     NVARCHAR(120) NOT NULL,
    DonorType     VARCHAR(20)   NOT NULL,
    Phone         VARCHAR(20)   NULL
);
/* Inventory: đúng Mã nguồn 1.1 của báo cáo */
IF OBJECT_ID(N'dbo.Inventory') IS NULL
CREATE TABLE dbo.Inventory (
    WarehouseID INT       NOT NULL FOREIGN KEY REFERENCES dbo.Warehouse(WarehouseID),
    ItemID      INT       NOT NULL FOREIGN KEY REFERENCES dbo.Item(ItemID),
    Quantity    INT       NOT NULL CONSTRAINT CKInventoryQty CHECK (Quantity >= 0),
    ReservedQty INT       NOT NULL DEFAULT 0 CHECK (ReservedQty >= 0),
    UpdatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PKInventory PRIMARY KEY CLUSTERED (WarehouseID, ItemID),
    CONSTRAINT CKInventoryReservedLeQty CHECK (ReservedQty <= Quantity)
);
IF OBJECT_ID(N'dbo.ReliefRequest') IS NULL
CREATE TABLE dbo.ReliefRequest (
    RequestID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PKReliefRequest PRIMARY KEY CLUSTERED,
    RegionID      INT          NOT NULL CONSTRAINT FKReliefRequestRegion REFERENCES dbo.Region(RegionID),
    ItemID        INT          NOT NULL CONSTRAINT FKReliefRequestItem REFERENCES dbo.Item(ItemID),
    RequestedQty  INT          NOT NULL CONSTRAINT CKReliefRequestQty CHECK (RequestedQty > 0),
    Status        VARCHAR(20)  NOT NULL CONSTRAINT DFReliefRequestStatus DEFAULT 'Pending',
    CreatedAt     DATETIME2    NOT NULL CONSTRAINT DFReliefRequestCreatedAt DEFAULT SYSUTCDATETIME()
);
IF OBJECT_ID(N'dbo.DispatchOrder') IS NULL
CREATE TABLE dbo.DispatchOrder (
    DispatchID    INT IDENTITY(1,1) NOT NULL CONSTRAINT PKDispatchOrder PRIMARY KEY CLUSTERED,
    RequestID     INT          NOT NULL CONSTRAINT FKDispatchOrderRequest   REFERENCES dbo.ReliefRequest(RequestID),
    WarehouseID   INT          NOT NULL CONSTRAINT FKDispatchOrderWarehouse REFERENCES dbo.Warehouse(WarehouseID),
    ItemID        INT          NOT NULL CONSTRAINT FKDispatchOrderItem      REFERENCES dbo.Item(ItemID),
    DonorID       INT          NULL     CONSTRAINT FKDispatchOrderDonor     REFERENCES dbo.Donor(DonorID),
    DispatchedQty INT          NOT NULL CONSTRAINT CKDispatchOrderQty CHECK (DispatchedQty > 0),
    DispatchedAt  DATETIME2    NOT NULL CONSTRAINT DFDispatchOrderDispatchedAt DEFAULT SYSUTCDATETIME()
);
IF OBJECT_ID(N'dbo.AuditLog') IS NULL
CREATE TABLE dbo.AuditLog (
    LogID         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PKAuditLog PRIMARY KEY CLUSTERED,
    WarehouseID   INT          NOT NULL CONSTRAINT FKAuditLogWarehouse REFERENCES dbo.Warehouse(WarehouseID),
    ItemID        INT          NOT NULL CONSTRAINT FKAuditLogItem      REFERENCES dbo.Item(ItemID),
    ActionType    VARCHAR(20)  NOT NULL,
    DeltaQty      INT          NOT NULL,
    LoggedAt      DATETIME2    NOT NULL CONSTRAINT DFAuditLogLoggedAt DEFAULT SYSUTCDATETIME()
);
GO
/* =====================================================================
   Hạ tầng đo của lab (schema lab) + schema exp cho object thí nghiệm
   ===================================================================== */
IF SCHEMA_ID(N'lab') IS NULL EXEC (N'CREATE SCHEMA lab');
IF SCHEMA_ID(N'exp') IS NULL EXEC (N'CREATE SCHEMA exp');
GO
IF OBJECT_ID(N'lab.RunContext') IS NULL
BEGIN
    CREATE TABLE lab.RunContext (
        Id           TINYINT NOT NULL CONSTRAINT PKRunContext PRIMARY KEY CHECK (Id = 1),
        PassNo       INT         NOT NULL,    -- 1 = lượt đầu, 2 = lượt chạy lại sau 09
        Mode         VARCHAR(10) NOT NULL     -- MEASURE: đo số liệu | PLAN: lượt riêng, chạy 1 lần lấy actual plan
                     CHECK (Mode IN ('MEASURE','PLAN'))
    );
    INSERT lab.RunContext VALUES (1, 1, 'MEASURE');
END
IF OBJECT_ID(N'lab.Measurement') IS NULL
CREATE TABLE lab.Measurement (
    MeasurementID BIGINT IDENTITY PRIMARY KEY,
    PassNo        INT           NOT NULL,
    CaseID        VARCHAR(40)   NOT NULL,
    Variant       NVARCHAR(120)  NOT NULL,
    RunNo         INT           NOT NULL,
    RowsReturned  BIGINT        NULL,
    LogicalReads  BIGINT        NOT NULL,
    CpuMs         INT           NOT NULL,
    ElapsedMs     INT           NOT NULL,   -- sys.dm_exec_requests.total_elapsed_time (độ phân giải 1 ms)
    Note          NVARCHAR(400) NULL,
    MeasuredAt    DATETIME2(3)  NOT NULL DEFAULT SYSDATETIME()
);
/* Dấu vân tay kết quả của mỗi biến thể đã đo (lượt MEASURE):
   BagHash   = SHA-256 của các dòng đã sắp theo nội dung  -> cùng tập dòng kể cả số lần xuất hiện
   OrderHash = SHA-256 của các dòng theo thứ tự trả về    -> cùng thứ tự */
IF OBJECT_ID(N'lab.Fingerprint') IS NULL
CREATE TABLE lab.Fingerprint (
    FingerprintID BIGINT IDENTITY PRIMARY KEY,
    PassNo        INT            NOT NULL,
    CaseID        VARCHAR(40)    NOT NULL,
    Variant       NVARCHAR(120)   NOT NULL,
    RowsReturned  BIGINT         NULL,
    BagHash       VARBINARY(32)  NULL,
    OrderHash     VARBINARY(32)  NULL,
    Error         NVARCHAR(400)  NULL,   -- vd. thủ tục không trả result set (cursor + PRINT)
    TakenAt       DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME()
);
IF OBJECT_ID(N'lab.Equivalence') IS NULL
CREATE TABLE lab.Equivalence (
    EquivalenceID BIGINT IDENTITY PRIMARY KEY,
    PassNo        INT          NOT NULL,
    CaseID        VARCHAR(40)  NOT NULL,
    VariantA      NVARCHAR(120) NOT NULL,
    VariantB      NVARCHAR(120) NOT NULL,
    RowsA         BIGINT       NULL,
    RowsB         BIGINT       NULL,
    BagEqual      BIT          NULL,
    OrderEqual    BIT          NULL,
    Expected      VARCHAR(10)  NOT NULL,   -- SAME = phải tương đương | DIFFERENT = minh họa khác nghĩa
    CheckedAt     DATETIME2(3) NOT NULL DEFAULT SYSDATETIME()
);
/* Hình dạng plan của mỗi biến thể (ghi ở lượt PLAN, lấy từ Query Store):
   PlanHashes = danh sách query_plan_hash của các câu lệnh dbo/exp đã chạy trong lượt đó */
IF OBJECT_ID(N'lab.PlanShape') IS NULL
CREATE TABLE lab.PlanShape (
    PlanShapeID BIGINT IDENTITY PRIMARY KEY,
    PassNo      INT            NOT NULL,
    CaseID      VARCHAR(40)    NOT NULL,
    Variant     NVARCHAR(120)  NOT NULL,
    Statements  INT            NOT NULL,
    PlanHashes  NVARCHAR(2000) NULL,
    TakenAt     DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME()
);
/* Danh mục truy vấn nghiệp vụ dùng chung giữa các lab (cùng câu chữ, cùng tham số) */
IF OBJECT_ID(N'lab.Query') IS NULL
CREATE TABLE lab.Query (
    QueryID   VARCHAR(10)    NOT NULL PRIMARY KEY,
    Title     NVARCHAR(200)  NOT NULL,
    Stmt      NVARCHAR(MAX)  NOT NULL,
    ParamDef  NVARCHAR(MAX)  NULL
);
GO
/* Trung vị theo (PassNo, CaseID, Variant) */
CREATE OR ALTER VIEW lab.vMeasureSummary AS
SELECT DISTINCT
    PassNo, CaseID, Variant,
    COUNT(*)            OVER (PARTITION BY PassNo, CaseID, Variant) AS Runs,
    MAX(RowsReturned)   OVER (PARTITION BY PassNo, CaseID, Variant) AS RowsReturned,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY LogicalReads) OVER (PARTITION BY PassNo, CaseID, Variant) AS MedianReads,
    MIN(LogicalReads)   OVER (PARTITION BY PassNo, CaseID, Variant) AS MinReads,
    MAX(LogicalReads)   OVER (PARTITION BY PassNo, CaseID, Variant) AS MaxReads,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY CpuMs) OVER (PARTITION BY PassNo, CaseID, Variant) AS MedianCpuMs,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY ElapsedMs) OVER (PARTITION BY PassNo, CaseID, Variant) AS MedianElapsedMs
FROM lab.Measurement;
GO
/* ---------------------------------------------------------------------
   lab.usp_Measure — làm nóng @Warmup lần rồi đo @Runs lần một truy vấn
   tham số hóa (sp_executesql). Logical reads / CPU lấy theo hiệu số của
   sys.dm_exec_requests cho chính phiên (logical_reads, cpu_time,
   total_elapsed_time — đều ms). Không dùng SYSDATETIME(): trong container
   amd64 trên Mac, đồng hồ này chỉ nhảy ~5,8 ms một lần.
   Kết quả truy vấn vẫn được gửi về client (cùng một cách thu kết quả cho
   mọi biến thể). Actual plan KHÔNG thu trong lượt đo: run_lab.sh chạy lại
   cả script ở Mode = 'PLAN', khi đó harness chỉ chạy mỗi biến thể 1 lần
   với STATISTICS XML/IO (không ghi số đo).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE lab.usp_Measure
    @CaseID    VARCHAR(40),
    @Variant   NVARCHAR(120),
    @Stmt      NVARCHAR(MAX),
    @ParamDef  NVARCHAR(MAX) = NULL,
    @ParamVals NVARCHAR(MAX) = NULL,   -- ví dụ: N'@RegionID = 1, @From = ''20250301'''
    @Runs      INT = 5,
    @Warmup    INT = 1,
    @FreshCompile BIT = 1,             -- 1: xóa plan cache của DB này trước biến thể => biên dịch theo tham số của chính nó
                                       -- 0: giữ cached plan (dùng cho lab parameter sniffing)
    @Note      NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pass INT, @mode VARCHAR(10);
    SELECT @pass = PassNo, @mode = Mode FROM lab.RunContext WHERE Id = 1;
    IF @FreshCompile = 1
        EXEC (N'ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;');

    DECLARE @outer NVARCHAR(MAX) = N'EXEC sys.sp_executesql @s'
        + CASE WHEN @ParamDef IS NULL THEN N'' ELSE N', @pd' + ISNULL(N', ' + @ParamVals, N'') END;
    DECLARE @i INT = 0, @r0 BIGINT, @r1 BIGINT, @c0 INT, @c1 INT, @e0 INT, @e1 INT, @rows BIGINT;
    DECLARE @msg NVARCHAR(400);

    IF @mode = 'PLAN'
    BEGIN
        SET @msg = CONCAT(N'##PLAN-BEGIN## ', @CaseID, N'|', @Variant, N'|pass', @pass);
        RAISERROR(N'%s', 0, 1, @msg) WITH NOWAIT;
        DECLARE @tp DATETIMEOFFSET = SYSDATETIMEOFFSET();
        WAITFOR DELAY '00:00:00.020';   -- đồng hồ container nhảy ~6 ms: tách hẳn mốc thời gian
        SET STATISTICS IO ON;
        SET STATISTICS XML ON;
        BEGIN TRY
            EXEC sys.sp_executesql @outer, N'@s NVARCHAR(MAX), @pd NVARCHAR(MAX)', @s = @Stmt, @pd = @ParamDef;
        END TRY
        BEGIN CATCH
            SET STATISTICS XML OFF;
            SET @msg = CONCAT(N'usp_Measure (PLAN) lỗi ở ', @CaseID, N' | ', @Variant, N': ', ERROR_MESSAGE());
            THROW 50111, @msg, 1;
        END CATCH;
        SET STATISTICS XML OFF;
        SET STATISTICS IO OFF;
        RAISERROR(N'##PLAN-END##', 0, 1) WITH NOWAIT;
        -- Hình dạng plan: các plan (Query Store) có lượt chạy sau @tp, bỏ câu lệnh của schema lab và truy vấn hệ thống
        DELETE lab.PlanShape WHERE PassNo = @pass AND CaseID = @CaseID AND Variant = @Variant;
        INSERT lab.PlanShape (PassNo, CaseID, Variant, Statements, PlanHashes)
        SELECT @pass, @CaseID, @Variant, COUNT(*),
               STRING_AGG(CONVERT(NVARCHAR(20), x.query_plan_hash, 1), N',') WITHIN GROUP (ORDER BY x.query_plan_hash)
        FROM (SELECT DISTINCT p.query_plan_hash
              FROM sys.query_store_runtime_stats rs
              JOIN sys.query_store_plan p ON p.plan_id = rs.plan_id
              JOIN sys.query_store_query q ON q.query_id = p.query_id
              JOIN sys.query_store_query_text t ON t.query_text_id = q.query_text_id
              WHERE rs.last_execution_time > @tp
                AND (q.object_id = 0 OR OBJECT_SCHEMA_NAME(q.object_id) IN (N'dbo', N'exp'))
                AND t.query_sql_text NOT LIKE N'%sys.%'
                AND t.query_sql_text NOT LIKE N'%lab.%'
                AND t.query_sql_text LIKE N'%dbo.%') x;
        RETURN;
    END;

    -- chạy lại cùng (pass, ca, biến thể) thì thay số đo cũ, không cộng dồn
    DELETE lab.Measurement WHERE PassNo = @pass AND CaseID = @CaseID AND Variant = @Variant;
    DELETE lab.Fingerprint WHERE PassNo = @pass AND CaseID = @CaseID AND Variant = @Variant;
    SET @msg = CONCAT(N'-- MEASURE ', @CaseID, N' | ', @Variant, N' | pass ', @pass);
    RAISERROR(N'%s', 0, 1, @msg) WITH NOWAIT;

    BEGIN TRY
    WHILE @i < @Warmup + @Runs
    BEGIN
        SELECT @r0 = logical_reads, @c0 = cpu_time, @e0 = total_elapsed_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        EXEC sys.sp_executesql @outer, N'@s NVARCHAR(MAX), @pd NVARCHAR(MAX)', @s = @Stmt, @pd = @ParamDef;
        SET @rows = @@ROWCOUNT;
        SELECT @r1 = logical_reads, @c1 = cpu_time, @e1 = total_elapsed_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        IF @i >= @Warmup
            INSERT lab.Measurement (PassNo, CaseID, Variant, RunNo, RowsReturned, LogicalReads, CpuMs, ElapsedMs, Note)
            VALUES (@pass, @CaseID, @Variant, @i - @Warmup + 1, @rows, @r1 - @r0, @c1 - @c0,
                    @e1 - @e0, @Note);
        SET @i += 1;
    END;
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(N'usp_Measure lỗi ở ', @CaseID, N' | ', @Variant, N': ', ERROR_MESSAGE());
        THROW 50110, @msg, 1;
    END CATCH;

    -- Dấu vân tay kết quả (một lần chạy thêm, không tính vào số đo)
    EXEC lab.usp_Fingerprint @CaseID, @Variant, @Stmt, @ParamDef, @ParamVals;

    SELECT m.CaseID, m.Variant, m.Runs, m.RowsReturned, m.MedianReads, m.MinReads, m.MaxReads,
           m.MedianCpuMs, m.MedianElapsedMs, CONVERT(CHAR(16), f.BagHash, 2) AS BagHash16
    FROM lab.vMeasureSummary m
    OUTER APPLY (SELECT TOP (1) BagHash FROM lab.Fingerprint f
                 WHERE f.PassNo = m.PassNo AND f.CaseID = m.CaseID AND f.Variant = m.Variant
                 ORDER BY f.FingerprintID DESC) f
    WHERE m.PassNo = @pass AND m.CaseID = @CaseID AND m.Variant = @Variant;
END;
GO
/* ---------------------------------------------------------------------
   lab.usp_Fingerprint — chạy truy vấn 1 lần, đổ kết quả vào bảng tạm
   (giữ thứ tự trả về bằng IDENTITY) rồi băm SHA-256:
   * OrderHash: các dòng theo thứ tự trả về
   * BagHash  : các dòng sắp theo nội dung -> bằng nhau khi cùng tập dòng
                và cùng số lần xuất hiện của từng dòng
   NULL hiển thị là ~NULL~ để phân biệt với chuỗi rỗng.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE lab.usp_Fingerprint
    @CaseID VARCHAR(40), @Variant NVARCHAR(120), @Stmt NVARCHAR(MAX),
    @ParamDef NVARCHAR(MAX) = NULL, @ParamVals NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pass INT = (SELECT PassNo FROM lab.RunContext WHERE Id = 1);
    DECLARE @defs NVARCHAR(MAX), @cols NVARCHAR(MAX), @expr NVARCHAR(MAX), @sql NVARCHAR(MAX);
    DECLARE @rows BIGINT, @bag VARBINARY(32), @ord VARBINARY(32);
    BEGIN TRY
        SELECT @defs = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name) + N' ' + system_type_name + N' NULL'), N', ')
                           WITHIN GROUP (ORDER BY column_ordinal),
               @cols = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)), N', ') WITHIN GROUP (ORDER BY column_ordinal),
               @expr = STRING_AGG(CONVERT(NVARCHAR(MAX), N'ISNULL(CONVERT(NVARCHAR(MAX), ' + QUOTENAME(name) + N'), N''~NULL~'')'),
                                  N', N''|'', ') WITHIN GROUP (ORDER BY column_ordinal)
        FROM sys.dm_exec_describe_first_result_set(@Stmt, @ParamDef, 0)
        WHERE is_hidden = 0;
        IF @cols IS NULL THROW 50100, N'Không mô tả được result set (truy vấn/thủ tục không trả tập kết quả cố định).', 1;

        DROP TABLE IF EXISTS ##lab_fp;
        SET @sql = N'CREATE TABLE ##lab_fp (lab_rn INT IDENTITY(1,1) PRIMARY KEY, ' + @defs + N');';
        EXEC (@sql);
        SET @sql = N'INSERT ##lab_fp (' + @cols + N') EXEC sys.sp_executesql @s'
                 + CASE WHEN @ParamDef IS NULL THEN N'' ELSE N', @pd' + ISNULL(N', ' + @ParamVals, N'') END;
        EXEC sys.sp_executesql @sql, N'@s NVARCHAR(MAX), @pd NVARCHAR(MAX)', @s = @Stmt, @pd = @ParamDef;

        SET @sql = N'SELECT lab_rn, CONCAT(' + @expr + N', N'''') COLLATE Latin1_General_BIN2 AS line INTO #lines FROM ##lab_fp;
                     SELECT @rows = COUNT_BIG(*),
                            @ord  = HASHBYTES(''SHA2_256'', ISNULL(STRING_AGG(line, NCHAR(10)) WITHIN GROUP (ORDER BY lab_rn), N''''))
                     FROM #lines;
                     SELECT @bag  = HASHBYTES(''SHA2_256'', ISNULL(STRING_AGG(line, NCHAR(10)) WITHIN GROUP (ORDER BY line), N''''))
                     FROM #lines;';
        EXEC sys.sp_executesql @sql, N'@rows BIGINT OUTPUT, @ord VARBINARY(32) OUTPUT, @bag VARBINARY(32) OUTPUT',
             @rows = @rows OUTPUT, @ord = @ord OUTPUT, @bag = @bag OUTPUT;
        DROP TABLE IF EXISTS ##lab_fp;
        INSERT lab.Fingerprint (PassNo, CaseID, Variant, RowsReturned, BagHash, OrderHash)
        VALUES (@pass, @CaseID, @Variant, @rows, @bag, @ord);
    END TRY
    BEGIN CATCH
        DROP TABLE IF EXISTS ##lab_fp;
        INSERT lab.Fingerprint (PassNo, CaseID, Variant, Error)
        VALUES (@pass, @CaseID, @Variant, LEFT(ERROR_MESSAGE(), 400));
    END CATCH;
END;
GO
/* ---------------------------------------------------------------------
   lab.usp_CheckSame — so dấu vân tay của 2 biến thể đã đo trong lượt hiện tại.
   @Expected = 'SAME'      : ném lỗi nếu khác (về tập dòng, hoặc thứ tự khi @OrderMatters = 1)
   @Expected = 'DIFFERENT' : chỉ ghi nhận (dùng cho cách viết cố ý khác nghĩa, vd NOT IN có NULL)
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE lab.usp_CheckSame
    @CaseID VARCHAR(40), @VariantA NVARCHAR(120), @VariantB NVARCHAR(120),
    @OrderMatters BIT = 0, @Expected VARCHAR(10) = 'SAME'
AS
BEGIN
    SET NOCOUNT ON;
    IF (SELECT Mode FROM lab.RunContext) = 'PLAN' RETURN;   -- lượt lấy plan không lặp lại phép so sánh
    DECLARE @pass INT = (SELECT PassNo FROM lab.RunContext WHERE Id = 1);
    DECLARE @ra BIGINT, @rb BIGINT, @ba VARBINARY(32), @bb VARBINARY(32), @oa VARBINARY(32), @ob VARBINARY(32);
    SELECT TOP (1) @ra = RowsReturned, @ba = BagHash, @oa = OrderHash FROM lab.Fingerprint
    WHERE PassNo = @pass AND CaseID = @CaseID AND Variant = @VariantA ORDER BY FingerprintID DESC;
    SELECT TOP (1) @rb = RowsReturned, @bb = BagHash, @ob = OrderHash FROM lab.Fingerprint
    WHERE PassNo = @pass AND CaseID = @CaseID AND Variant = @VariantB ORDER BY FingerprintID DESC;
    IF @ba IS NULL OR @bb IS NULL
        THROW 50102, N'usp_CheckSame: thiếu dấu vân tay của một biến thể.', 1;
    DECLARE @bag BIT = IIF(@ba = @bb AND @ra = @rb, 1, 0);
    DECLARE @ord BIT = CASE WHEN @OrderMatters = 1 THEN IIF(@oa = @ob, 1, 0) END;
    DELETE lab.Equivalence WHERE PassNo = @pass AND CaseID = @CaseID AND VariantA = @VariantA AND VariantB = @VariantB;
    INSERT lab.Equivalence (PassNo, CaseID, VariantA, VariantB, RowsA, RowsB, BagEqual, OrderEqual, Expected)
    VALUES (@pass, @CaseID, @VariantA, @VariantB, @ra, @rb, @bag, @ord, @Expected);
    SELECT @CaseID AS CaseID, @VariantA AS VariantA, @VariantB AS VariantB, @ra AS RowsA, @rb AS RowsB,
           @bag AS BagEqual, @ord AS OrderEqual, @Expected AS Expected;
    IF @Expected = 'SAME' AND (@bag = 0 OR @ord = 0)
    BEGIN
        DECLARE @e NVARCHAR(400) = CONCAT(N'Kết quả KHÔNG tương đương: ', @CaseID, N' | ', @VariantA, N' vs ', @VariantB);
        THROW 50101, @e, 1;
    END;
END;
GO
/* lab.usp_MeasureQ — đo một truy vấn trong danh mục lab.Query (cùng câu chữ giữa các lab) */
CREATE OR ALTER PROCEDURE lab.usp_MeasureQ
    @CaseID VARCHAR(40), @Variant NVARCHAR(120), @QueryID VARCHAR(10),
    @ParamVals NVARCHAR(MAX) = NULL, @FreshCompile BIT = 1, @Note NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @s NVARCHAR(MAX), @pd NVARCHAR(MAX);
    SELECT @s = Stmt, @pd = ParamDef FROM lab.Query WHERE QueryID = @QueryID;
    IF @s IS NULL THROW 50103, N'QueryID không có trong lab.Query.', 1;
    EXEC lab.usp_Measure @CaseID = @CaseID, @Variant = @Variant, @Stmt = @s, @ParamDef = @pd,
                         @ParamVals = @ParamVals, @FreshCompile = @FreshCompile, @Note = @Note;
END;
GO
/* ---------------------------------------------------------------------
   lab.usp_ResetLab — đưa database về trạng thái đầu vào đã công bố:
   * xóa mọi object trong schema exp (view/proc/function thí nghiệm)
   * xóa mọi index không phải PK/unique constraint trên bảng dbo
   * xóa statistics do lab/auto tạo, UPDATE STATISTICS ... WITH FULLSCAN
   * compat 170, PSP = ON, CE_FEEDBACK(+FOR_EXPRESSIONS) = OFF, LAST_QUERY_PLAN_STATS = OFF, xóa XE session lab
   * xóa plan cache của riêng database này
   KHÔNG đụng dữ liệu seed, khóa, Query Store, bảng lab.*.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE lab.usp_ResetLab
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX) = N'';
    -- view có index phải xóa trước (schemabinding)
    SELECT @sql += N'DROP VIEW ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N'; '
    FROM sys.objects o WHERE SCHEMA_NAME(o.schema_id) = N'exp' AND o.type = 'V';
    SELECT @sql += N'DROP PROCEDURE ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N'; '
    FROM sys.objects o WHERE SCHEMA_NAME(o.schema_id) = N'exp' AND o.type = 'P';
    SELECT @sql += N'DROP FUNCTION ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N'; '
    FROM sys.objects o WHERE SCHEMA_NAME(o.schema_id) = N'exp' AND o.type IN ('FN','IF','TF');
    SELECT @sql += N'DROP TABLE ' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N'; '
    FROM sys.objects o WHERE SCHEMA_NAME(o.schema_id) = N'exp' AND o.type = 'U';
    EXEC (@sql);

    SET @sql = N'';
    SELECT @sql += N'DROP INDEX ' + QUOTENAME(i.name) + N' ON dbo.' + QUOTENAME(t.name) + N'; '
    FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
    WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND i.index_id > 1
      AND i.is_primary_key = 0 AND i.is_unique_constraint = 0;
    EXEC (@sql);

    SET @sql = N'';
    SELECT @sql += N'DROP STATISTICS dbo.' + QUOTENAME(t.name) + N'.' + QUOTENAME(s.name) + N'; '
    FROM sys.stats s JOIN sys.tables t ON t.object_id = s.object_id
    WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND (s.auto_created = 1 OR s.user_created = 1);
    EXEC (@sql);

    SET @sql = N'';
    SELECT @sql += N'UPDATE STATISTICS dbo.' + QUOTENAME(t.name) + N' WITH FULLSCAN; '
    FROM sys.tables t WHERE SCHEMA_NAME(t.schema_id) = N'dbo';
    EXEC (@sql);

    EXEC (N'ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = OFF;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET CE_FEEDBACK = OFF;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION SET CE_FEEDBACK_FOR_EXPRESSIONS = OFF;');
    IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'lab_psp')
        EXEC (N'DROP EVENT SESSION lab_psp ON SERVER;');
    EXEC (N'ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;');
    PRINT N'lab.usp_ResetLab: đã đưa về baseline (chỉ PK, stats FULLSCAN, compat 170, PSP ON, CE feedback OFF).';
END;
GO
/* ---------- Kiểm tra cấu hình sau khi tạo ---------- */
SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) AS ProductMajorVersion,
       CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(30)) AS ProductVersion,
       CAST(SERVERPROPERTY('ProductUpdateLevel') AS VARCHAR(10)) AS UpdateLevel,
       CAST(SERVERPROPERTY('Edition') AS VARCHAR(60)) AS Edition,
       d.compatibility_level, d.recovery_model_desc, d.collation_name,
       qs.actual_state_desc AS QueryStoreState, qs.query_capture_mode_desc
FROM sys.databases d CROSS JOIN sys.database_query_store_options qs
WHERE d.name = DB_NAME();
IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) <> 17
    THROW 50004, N'Cần SQL Server 2025 (ProductMajorVersion = 17).', 1;
SELECT COUNT(*) AS Tables, (SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t2 ON t2.object_id = c.object_id
                            WHERE SCHEMA_NAME(t2.schema_id) = N'dbo') AS Columns
FROM sys.tables t WHERE SCHEMA_NAME(t.schema_id) = N'dbo';
GO
