SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_ID(N'DisasterReliefDB') IS NULL
    THROW 50100, N'Chưa có database DisasterReliefDB. Script không tự tạo database — xem README mục 2.', 1;
GO
USE DisasterReliefDB;
DECLARE @expected TABLE (name sysname PRIMARY KEY);
INSERT @expected VALUES (N'Region'),(N'Warehouse'),(N'Category'),(N'Item'),(N'Donor'),
                        (N'Inventory'),(N'ReliefRequest'),(N'DispatchOrder'),(N'AuditLog');

DECLARE @unexpected NVARCHAR(MAX) =
   (SELECT STRING_AGG(CONCAT(SCHEMA_NAME(t.schema_id), N'.', t.name), N', ')
    FROM sys.tables t
    WHERE t.is_ms_shipped = 0
      AND NOT (SCHEMA_NAME(t.schema_id) = N'dbo' AND t.name IN (SELECT name FROM @expected)));
IF @unexpected IS NOT NULL
BEGIN
    DECLARE @m1 NVARCHAR(2048) = CONCAT(N'Database có bảng ngoài thiết kế (', @unexpected, N') — dừng để không ghi đè.');
    THROW 50101, @m1, 1;
END;

DECLARE @present INT = (SELECT COUNT(*) FROM sys.tables t
                        WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND t.name IN (SELECT name FROM @expected));
IF @present NOT IN (0, 9)
    THROW 50102, N'Chỉ có một phần trong 9 bảng — trạng thái dở dang, cần kiểm tra thủ công.', 1;
IF @present = 9
BEGIN
    DECLARE @cols INT = (SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id
                         WHERE SCHEMA_NAME(t.schema_id) = N'dbo' AND t.name IN (SELECT name FROM @expected));
    IF @cols <> 44 THROW 50103, N'9 bảng đã có nhưng số cột khác 44 — lược đồ không khớp báo cáo.', 1;
    PRINT N'9 bảng / 44 cột đã tồn tại — bỏ qua bước tạo bảng.';
    RETURN;
END
PRINT N'Database rỗng — tạo 9 bảng.';
BEGIN TRANSACTION;

CREATE TABLE dbo.Region (
    RegionID      INT           NOT NULL CONSTRAINT PKRegion PRIMARY KEY CLUSTERED,
    RegionName    NVARCHAR(100) NOT NULL,
    SeverityLevel TINYINT       NOT NULL CONSTRAINT CKRegionSeverity CHECK (SeverityLevel BETWEEN 1 AND 5),
    AffectedPop   INT           NOT NULL
);

CREATE TABLE dbo.Warehouse (
    WarehouseID   INT           NOT NULL CONSTRAINT PKWarehouse PRIMARY KEY CLUSTERED,
    RegionID      INT           NOT NULL CONSTRAINT FKWarehouseRegion REFERENCES dbo.Region (RegionID),
    WarehouseName NVARCHAR(100) NOT NULL,
    Capacity      INT           NOT NULL
);

CREATE TABLE dbo.Category (
    CategoryID    INT           NOT NULL CONSTRAINT PKCategory PRIMARY KEY CLUSTERED,
    CategoryName  NVARCHAR(80)  NOT NULL,
    IsPerishable  BIT           NOT NULL
);

CREATE TABLE dbo.Item (
    ItemID        INT           NOT NULL CONSTRAINT PKItem PRIMARY KEY CLUSTERED,
    CategoryID    INT           NOT NULL CONSTRAINT FKItemCategory REFERENCES dbo.Category (CategoryID),
    ItemName      NVARCHAR(100) NOT NULL,
    Unit          NVARCHAR(20)  NOT NULL,
    UnitWeight    DECIMAL(8,2)  NOT NULL
);

CREATE TABLE dbo.Donor (
    DonorID       INT           NOT NULL CONSTRAINT PKDonor PRIMARY KEY CLUSTERED,
    DonorName     NVARCHAR(120) NOT NULL,
    DonorType     VARCHAR(20)   NOT NULL,
    Phone         VARCHAR(20)   NULL
);

/* Inventory: nguyên văn Mã nguồn 1.1 (FK/DEFAULT/CHECK ReservedQty không đặt tên, như báo cáo) */
CREATE TABLE dbo.Inventory (
    WarehouseID INT       NOT NULL FOREIGN KEY REFERENCES dbo.Warehouse(WarehouseID),
    ItemID      INT       NOT NULL FOREIGN KEY REFERENCES dbo.Item(ItemID),
    Quantity    INT       NOT NULL CONSTRAINT CKInventoryQty CHECK (Quantity >= 0),
    ReservedQty INT       NOT NULL DEFAULT 0 CHECK (ReservedQty >= 0),
    UpdatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PKInventory PRIMARY KEY CLUSTERED (WarehouseID, ItemID),
    CONSTRAINT CKInventoryReservedLeQty CHECK (ReservedQty <= Quantity)
);

CREATE TABLE dbo.ReliefRequest (
    RequestID     INT IDENTITY(1,1) NOT NULL CONSTRAINT PKReliefRequest PRIMARY KEY CLUSTERED,
    RegionID      INT          NOT NULL CONSTRAINT FKReliefRequestRegion REFERENCES dbo.Region (RegionID),
    ItemID        INT          NOT NULL CONSTRAINT FKReliefRequestItem   REFERENCES dbo.Item (ItemID),
    RequestedQty  INT          NOT NULL,
    Status        VARCHAR(20)  NOT NULL CONSTRAINT DFReliefRequestStatus    DEFAULT 'Pending',
    CreatedAt     DATETIME2    NOT NULL CONSTRAINT DFReliefRequestCreatedAt DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.DispatchOrder (
    DispatchID    INT IDENTITY(1,1) NOT NULL CONSTRAINT PKDispatchOrder PRIMARY KEY CLUSTERED,
    RequestID     INT          NOT NULL CONSTRAINT FKDispatchOrderRequest   REFERENCES dbo.ReliefRequest (RequestID),
    WarehouseID   INT          NOT NULL CONSTRAINT FKDispatchOrderWarehouse REFERENCES dbo.Warehouse (WarehouseID),
    ItemID        INT          NOT NULL CONSTRAINT FKDispatchOrderItem      REFERENCES dbo.Item (ItemID),
    DonorID       INT          NULL     CONSTRAINT FKDispatchOrderDonor     REFERENCES dbo.Donor (DonorID),
    DispatchedQty INT          NOT NULL,
    DispatchedAt  DATETIME2    NOT NULL CONSTRAINT DFDispatchOrderDispatchedAt DEFAULT SYSUTCDATETIME()
);

/* AuditLog: theo ERD không có FK (C2) */
CREATE TABLE dbo.AuditLog (
    LogID         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PKAuditLog PRIMARY KEY CLUSTERED,
    WarehouseID   INT          NOT NULL,
    ItemID        INT          NOT NULL,
    ActionType    VARCHAR(20)  NOT NULL,
    DeltaQty      INT          NOT NULL,
    LoggedAt      DATETIME2    NOT NULL CONSTRAINT DFAuditLogLoggedAt DEFAULT SYSUTCDATETIME()
);

COMMIT TRANSACTION;
PRINT N'Đã tạo 9 bảng.';
GO
/* ---------- Tóm tắt cấu trúc (luôn chạy) ---------- */
USE DisasterReliefDB;
SELECT t.name AS TableName, COUNT(*) AS Cols
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
WHERE SCHEMA_NAME(t.schema_id) = N'dbo'
GROUP BY t.name ORDER BY t.name;
GO
